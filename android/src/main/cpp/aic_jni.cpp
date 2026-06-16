#include <jni.h>
#include <android/log.h>
#include <vector>
#include <mutex>
#include <cstdint>
#include <cstring>
#include "aic.h"

#define LOG_TAG "QuailJNI"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

// In C++ the C struct/enum tag names (AicModel, AicErrorCode, ...) are usable
// directly as type names, so no `struct`/`enum` keyword is needed below.
struct QuailState {
    AicModel *model = nullptr;
    AicProcessor *processor = nullptr;
    AicProcessorContext *context = nullptr;
    size_t optimalFrames = 0;
    std::vector<float> pending;  // accumulated input samples awaiting a full model frame
    std::vector<float> scratch;  // one model-frame working buffer
    int lastError = 0;           // last process rc; read+cleared by nativeTakeError
    std::mutex mutex;            // guards pending/scratch vs nativeReset on another thread
};

constexpr uint32_t kSampleRate = 24000;

void destroyState(QuailState *st) {
    if (st == nullptr) return;
    aic_processor_context_destroy(st->context);
    aic_processor_destroy(st->processor);
    aic_model_destroy(st->model);
    delete st;
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_expo_modules_twowayaudio_QuailProcessor_nativeCreate(
        JNIEnv *env, jclass, jstring licenseKey, jstring modelPath, jintArray outError) {
    auto setError = [&](int code) {
        if (outError != nullptr) {
            jint c = code;
            env->SetIntArrayRegion(outError, 0, 1, &c);
        }
    };

    const char *keyC = env->GetStringUTFChars(licenseKey, nullptr);
    const char *pathC = env->GetStringUTFChars(modelPath, nullptr);
    // GetStringUTFChars returns null on allocation failure; releasing a null
    // pointer is undefined behavior, so bail before constructing any state.
    if (keyC == nullptr || pathC == nullptr) {
        if (keyC != nullptr) env->ReleaseStringUTFChars(licenseKey, keyC);
        if (pathC != nullptr) env->ReleaseStringUTFChars(modelPath, pathC);
        setError((int) AIC_ERROR_CODE_NULL_POINTER);
        return 0;
    }
    auto release = [&]() {
        env->ReleaseStringUTFChars(licenseKey, keyC);
        env->ReleaseStringUTFChars(modelPath, pathC);
    };

    auto *st = new QuailState();

    AicErrorCode rc = aic_model_create_from_file(&st->model, pathC);
    if (rc != AIC_ERROR_CODE_SUCCESS || st->model == nullptr) {
        LOGE("model_create_from_file failed: %d", rc);
        setError((int) rc); release(); destroyState(st); return 0;
    }

    rc = aic_model_get_optimal_num_frames(st->model, kSampleRate, &st->optimalFrames);
    if (rc != AIC_ERROR_CODE_SUCCESS || st->optimalFrames == 0) {
        LOGE("get_optimal_num_frames failed: %d", rc);
        setError((int) rc); release(); destroyState(st); return 0;
    }

    rc = aic_processor_create(&st->processor, st->model, keyC, nullptr);
    if (rc != AIC_ERROR_CODE_SUCCESS || st->processor == nullptr) {
        LOGE("processor_create failed: %d", rc);
        setError((int) rc); release(); destroyState(st); return 0;
    }

    rc = aic_processor_initialize(st->processor, kSampleRate, 1, st->optimalFrames, false);
    if (rc != AIC_ERROR_CODE_SUCCESS) {
        LOGE("processor_initialize failed: %d", rc);
        setError((int) rc); release(); destroyState(st); return 0;
    }

    rc = aic_processor_context_create(&st->context, st->processor);
    if (rc != AIC_ERROR_CODE_SUCCESS || st->context == nullptr) {
        LOGE("context_create failed: %d", rc);
        setError((int) rc); release(); destroyState(st); return 0;
    }

    st->scratch.resize(st->optimalFrames);
    st->pending.reserve(st->optimalFrames * 4);

    release();
    setError(0);
    return reinterpret_cast<jlong>(st);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_expo_modules_twowayaudio_QuailProcessor_nativeProcess(
        JNIEnv *env, jclass, jlong handle, jbyteArray input, jint lenBytes) {
    auto *st = reinterpret_cast<QuailState *>(handle);
    if (st == nullptr || lenBytes <= 0) {
        return env->NewByteArray(0);
    }
    std::lock_guard<std::mutex> lock(st->mutex);

    // Clamp to the real array length so a caller passing a stale/oversized
    // lenBytes can't drive an out-of-bounds read of `raw`. An odd lenBytes is
    // safe: sampleCount truncates, so the loop reads at most 2*(lenBytes/2)
    // <= lenBytes bytes (the trailing odd byte is simply dropped).
    const jsize arrayLen = env->GetArrayLength(input);
    if (lenBytes > arrayLen) lenBytes = arrayLen;
    const jsize sampleCount = lenBytes / 2;
    jbyte *raw = env->GetByteArrayElements(input, nullptr);
    if (raw == nullptr) return env->NewByteArray(0);
    auto *bytes = reinterpret_cast<uint8_t *>(raw);
    for (jsize i = 0; i < sampleCount; ++i) {
        int16_t s = (int16_t) (bytes[i * 2] | (bytes[i * 2 + 1] << 8));
        st->pending.push_back((float) s / 32768.0f);
    }
    env->ReleaseByteArrayElements(input, raw, JNI_ABORT);

    std::vector<float> out;
    size_t pos = 0;
    while (st->pending.size() - pos >= st->optimalFrames) {
        std::memcpy(st->scratch.data(), st->pending.data() + pos,
                    st->optimalFrames * sizeof(float));
        float *channel = st->scratch.data();
        AicErrorCode rc =
            aic_processor_process_planar(st->processor, &channel, 1, st->optimalFrames);
        if (rc != AIC_ERROR_CODE_SUCCESS) {
            st->lastError = (int) rc;
            // Pass through everything still buffered (originals) so no audio is lost.
            out.insert(out.end(), st->pending.begin() + pos, st->pending.end());
            pos = st->pending.size();
            break;
        }
        out.insert(out.end(), st->scratch.begin(), st->scratch.end());
        pos += st->optimalFrames;
    }
    st->pending.erase(st->pending.begin(), st->pending.begin() + pos);

    const jsize outBytes = (jsize) (out.size() * 2);
    jbyteArray result = env->NewByteArray(outBytes);
    // Null on JVM allocation failure; return null (Kotlin latches + passes through)
    // rather than dereferencing it in SetByteArrayRegion below.
    if (result == nullptr) return nullptr;
    if (outBytes > 0) {
        std::vector<jbyte> buf(outBytes);
        for (size_t i = 0; i < out.size(); ++i) {
            float f = out[i];
            if (f > 1.0f) f = 1.0f; else if (f < -1.0f) f = -1.0f;
            int16_t s = (int16_t) (f * 32767.0f);
            buf[i * 2] = (jbyte) (s & 0xFF);
            buf[i * 2 + 1] = (jbyte) ((s >> 8) & 0xFF);
        }
        env->SetByteArrayRegion(result, 0, outBytes, buf.data());
    }
    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_expo_modules_twowayaudio_QuailProcessor_nativeTakeError(
        JNIEnv *, jclass, jlong handle) {
    auto *st = reinterpret_cast<QuailState *>(handle);
    if (st == nullptr) return 0;
    std::lock_guard<std::mutex> lock(st->mutex);
    int e = st->lastError;
    st->lastError = 0;
    return e;
}

extern "C" JNIEXPORT void JNICALL
Java_expo_modules_twowayaudio_QuailProcessor_nativeSetEnabled(
        JNIEnv *, jclass, jlong handle, jboolean enabled) {
    auto *st = reinterpret_cast<QuailState *>(handle);
    if (st == nullptr || st->context == nullptr) return;
    // BYPASS: 0.0 = enhance, 1.0 = latency-compensated passthrough.
    aic_processor_context_set_parameter(
        st->context, AIC_PROCESSOR_PARAMETER_BYPASS, enabled ? 0.0f : 1.0f);
}

extern "C" JNIEXPORT void JNICALL
Java_expo_modules_twowayaudio_QuailProcessor_nativeReset(
        JNIEnv *, jclass, jlong handle) {
    auto *st = reinterpret_cast<QuailState *>(handle);
    if (st == nullptr) return;
    std::lock_guard<std::mutex> lock(st->mutex);
    if (st->context != nullptr) aic_processor_context_reset(st->context);
    st->pending.clear();
    st->lastError = 0;
}

extern "C" JNIEXPORT void JNICALL
Java_expo_modules_twowayaudio_QuailProcessor_nativeDestroy(
        JNIEnv *, jclass, jlong handle) {
    destroyState(reinterpret_cast<QuailState *>(handle));
}
