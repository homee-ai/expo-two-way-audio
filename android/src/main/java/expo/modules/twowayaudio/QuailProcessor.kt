package expo.modules.twowayaudio

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Wraps the aic-sdk Quail speech-enhancement processor (via the JNI shim) for
 * the outgoing mic path.
 *
 * Threading: [process] is only ever called from the AudioEngine mic-tap thread
 * (the SDK process call is real-time safe but not thread-safe). [setEnabled] and
 * [reset] go through the SDK's thread-safe context and the shim's mutex, so they
 * are safe to call from any thread.
 */
class QuailProcessor private constructor(private var handle: Long) {

    /**
     * Latched on the first process() error; from then on input passes through raw.
     * @Volatile publishes the latch across threads: written on the mic-tap thread
     * (process()) and cleared on the JS-bridge thread (reset()).
     */
    @Volatile
    private var hasFailed = false
    var onError: ((String) -> Unit)? = null

    val isAvailable: Boolean
        get() = handle != 0L && !hasFailed

    /**
     * Feeds raw Int16-LE PCM mic bytes; returns the enhanced Int16-LE bytes that
     * are ready — a multiple of the model frame size, possibly EMPTY while still
     * accumulating toward a full frame. On the first SDK error this latches
     * [hasFailed], reports via [onError], and returns best-effort/passthrough
     * audio so nothing is dropped.
     */
    fun process(input: ByteArray): ByteArray {
        if (hasFailed || handle == 0L) return input
        // nativeProcess can return null if the JVM fails to allocate the output
        // array (native OOM); latch + pass the raw input through so audio is never
        // dropped and the non-null contract downstream holds.
        val out = nativeProcess(handle, input, input.size) ?: run {
            hasFailed = true
            onError?.invoke("nativeProcess returned null (native allocation failed)")
            return input
        }
        val rc = nativeTakeError(handle)
        if (rc != 0) {
            hasFailed = true
            onError?.invoke("aic_processor_process_planar failed: $rc")
        }
        return out
    }

    /**
     * Enhancement toggle. Disabled uses the SDK's latency-compensated bypass
     * (output delay unchanged), so flipping mid-stream produces no clicks.
     */
    fun setEnabled(enabled: Boolean) {
        if (handle != 0L) nativeSetEnabled(handle, enabled)
    }

    /**
     * Clears SDK state + the accumulator and un-latches [hasFailed] for a
     * per-session retry. Call between sessions and after interruptions.
     */
    fun reset() {
        if (handle != 0L) nativeReset(handle)
        hasFailed = false
    }

    fun destroy() {
        if (handle != 0L) {
            nativeDestroy(handle)
            handle = 0L
        }
    }

    /** Thrown when the native processor cannot be created; [code] is the SDK rc. */
    class InitError(val code: Int) : Exception("aic processor create failed: code=$code")

    companion object {
        private const val MODEL_ASSET = "quail_vf_2_1_s_16khz_5i8jb8of_v12.aicmodel"

        // Sentinel rc for "native libraries could not be loaded" (no SDK call was
        // reached), distinct from the SDK's non-negative error codes.
        private const val NATIVE_UNAVAILABLE = -1

        // We ship arm64-v8a only; on any other ABI the .so is absent and
        // loadLibrary throws UnsatisfiedLinkError. Catch it so the class still
        // initializes and invoke() can fail gracefully into the relay path
        // instead of crashing the app (the error escapes initialize()'s
        // catch(Exception) otherwise — UnsatisfiedLinkError is an Error).
        @Volatile
        private var nativeLibLoaded = false

        init {
            nativeLibLoaded = try {
                // Load the prebuilt SDK first so the shim's DT_NEEDED resolves on all
                // supported API levels (older linkers don't auto-resolve siblings).
                System.loadLibrary("aic")
                System.loadLibrary("twowayaudio_aic")
                true
            } catch (t: UnsatisfiedLinkError) {
                Log.e("QuailProcessor", "native voice-focus libraries unavailable for this ABI", t)
                false
            }
        }

        /**
         * Creates a processor, throwing [InitError] (with the SDK rc, or
         * [NATIVE_UNAVAILABLE] when the native libraries failed to load) on failure.
         */
        @Throws(InitError::class)
        operator fun invoke(licenseKey: String, modelPath: String): QuailProcessor {
            if (!nativeLibLoaded) throw InitError(NATIVE_UNAVAILABLE)
            val err = IntArray(1)
            val handle = nativeCreate(licenseKey, modelPath, err)
            if (handle == 0L) throw InitError(err[0])
            return QuailProcessor(handle)
        }

        /**
         * Copies the bundled .aicmodel from APK assets to filesDir (assets have no
         * fopen-able path) and returns the absolute path, or null on failure. The
         * copy is skipped when an identically-named file already exists; the model
         * filename carries its version, so an upgrade lands under a new name.
         */
        fun copyBundledModel(context: Context): String? = try {
            val outFile = File(context.filesDir, MODEL_ASSET)
            if (!outFile.exists() || outFile.length() == 0L) {
                // Copy to a temp file then atomically rename, so a crash/kill/disk-full
                // mid-copy can't leave a partial file that exists() accepts on the next
                // launch (which would fail model load forever).
                val tempFile = File.createTempFile("model_", ".tmp", context.filesDir)
                try {
                    context.assets.open(MODEL_ASSET).use { input ->
                        tempFile.outputStream().use { output -> input.copyTo(output) }
                    }
                    if (!tempFile.renameTo(outFile)) {
                        throw java.io.IOException("failed to rename model temp file to $outFile")
                    }
                } catch (e: Exception) {
                    tempFile.delete()
                    throw e
                }
            }
            outFile.absolutePath
        } catch (e: Exception) {
            Log.e("QuailProcessor", "model copy failed", e)
            null
        }

        @JvmStatic private external fun nativeCreate(licenseKey: String, modelPath: String, outError: IntArray): Long
        @JvmStatic private external fun nativeProcess(handle: Long, input: ByteArray, len: Int): ByteArray?
        @JvmStatic private external fun nativeTakeError(handle: Long): Int
        @JvmStatic private external fun nativeSetEnabled(handle: Long, enabled: Boolean)
        @JvmStatic private external fun nativeReset(handle: Long)
        @JvmStatic private external fun nativeDestroy(handle: Long)
    }
}
