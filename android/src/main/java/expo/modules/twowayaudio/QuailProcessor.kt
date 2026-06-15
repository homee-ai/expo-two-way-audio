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
        val out = nativeProcess(handle, input, input.size)
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

        init {
            // Load the prebuilt SDK first so the shim's DT_NEEDED resolves on all
            // supported API levels (older linkers don't auto-resolve siblings).
            System.loadLibrary("aic")
            System.loadLibrary("twowayaudio_aic")
        }

        /**
         * Creates a processor, throwing [InitError] (with the SDK rc) on failure.
         */
        @Throws(InitError::class)
        operator fun invoke(licenseKey: String, modelPath: String): QuailProcessor {
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
                context.assets.open(MODEL_ASSET).use { input ->
                    outFile.outputStream().use { output -> input.copyTo(output) }
                }
            }
            outFile.absolutePath
        } catch (e: Exception) {
            Log.e("QuailProcessor", "model copy failed", e)
            null
        }

        @JvmStatic private external fun nativeCreate(licenseKey: String, modelPath: String, outError: IntArray): Long
        @JvmStatic private external fun nativeProcess(handle: Long, input: ByteArray, len: Int): ByteArray
        @JvmStatic private external fun nativeTakeError(handle: Long): Int
        @JvmStatic private external fun nativeSetEnabled(handle: Long, enabled: Boolean)
        @JvmStatic private external fun nativeReset(handle: Long)
        @JvmStatic private external fun nativeDestroy(handle: Long)
    }
}
