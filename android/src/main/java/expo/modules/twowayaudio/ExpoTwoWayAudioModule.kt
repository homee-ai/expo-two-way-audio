package expo.modules.twowayaudio

import android.content.Context
import androidx.core.os.bundleOf
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.Promise
import expo.modules.interfaces.permissions.Permissions

class ExpoTwoWayAudioModule : Module() {
    companion object {
        private const val ON_MIC_DATA_EVENT = "onMicrophoneData"
        private const val ON_INPUT_VOLUME_LEVEL_EVENT = "onInputVolumeLevelData"
        private const val ON_OUTPUT_VOLUME_LEVEL_EVENT = "onOutputVolumeLevelData"
        private const val ON_RECORDING_CHANGE_EVENT = "onRecordingChange"
        private const val ON_AUDIO_INTERRUPTION_EVENT = "onAudioInterruption"
        private const val ON_PLAYBACK_QUEUE_EMPTY_EVENT = "onPlaybackQueueEmpty"
        private const val ON_VOICE_FOCUS_ERROR_EVENT = "onVoiceFocusError"
        var audioEngine: AudioEngine? = null
        var quailProcessor: QuailProcessor? = null
        var quailInitAttempted = false
    }

    override fun definition() = ModuleDefinition {
        Name("ExpoTwoWayAudio")
        AsyncFunction("initialize") { voiceFocusLicenseKey: String?, promise: Promise ->
            try {
                if (audioEngine != null) {
                    promise.resolve(true)
                    return@AsyncFunction
                }
                val context = appContext.reactContext
                if (context == null) {
                    promise.resolve(false)
                    return@AsyncFunction
                }
                // Create the processor before the engine so it can be injected; a
                // failed/absent key leaves voiceFocus null and the relay path is used.
                ensureQuailProcessor(context, voiceFocusLicenseKey)
                audioEngine = AudioEngine(context)
                // Android captures at a fixed 24 kHz (AudioRecord SAMPLE_RATE), the
                // processor's configured rate, so no sample-rate mismatch is possible.
                audioEngine?.voiceFocus = quailProcessor
                quailProcessor?.reset()
                setupCallbacks()
                promise.resolve(true)
            } catch (e: Exception) {
                promise.resolve(false)
            }
        }

        Function("isVoiceFocusAvailable") {
            // Reads the engine's injected reference: "available" means wired into
            // the live pipeline.
            audioEngine?.voiceFocus?.isAvailable ?: false
        }

        Function("setVoiceFocusEnabled") { enabled: Boolean ->
            quailProcessor?.setEnabled(enabled)
        }

         Function("isRecording") {
             audioEngine?.isRecording ?: false
         }

         Function("toggleRecording") { value: Boolean ->
             audioEngine?.let { engine ->
                 val isRecording = engine.toggleRecording(value)
                 sendEvent(ON_RECORDING_CHANGE_EVENT, mapOf("data" to isRecording))
                 isRecording
             } ?: false
         }

         Function("tearDown") {
             audioEngine?.tearDown()
             audioEngine = null
             null
         }

         Function("restart") {
             audioEngine?.resumeRecordingAndPlayer()
             sendEvent(ON_RECORDING_CHANGE_EVENT, mapOf(
                 "data" to (audioEngine?.isRecording ?: false)
             ))
         }

         Function("playPCMData") { data: kotlin.ByteArray ->
             audioEngine?.playPCMData(data)
         }

         Function("flushPlayback") {
             audioEngine?.flushPlayback()
         }

         Function("bypassVoiceProcessing") { bypass: Boolean ->
             audioEngine?.bypassVoiceProcessing(bypass)
         }

         Function("isPlaying") {
             audioEngine?.isPlaying ?: false
         }

        Function("getMicrophoneModeIOS") {
            throw UnsupportedOperationException("getMicrophoneModeIOS is only supported on iOS")
        }

        Function ("setMicrophoneModeIOS") {
            throw UnsupportedOperationException("setMicrophoneModeIOS is only supported on iOS")
        }

         AsyncFunction("getMicrophonePermissionsAsync") { promise: Promise ->
             Permissions.getPermissionsWithPermissionsManager(
                 appContext.permissions,
                 promise,
                 android.Manifest.permission.RECORD_AUDIO
             )
         }

         AsyncFunction("requestMicrophonePermissionsAsync") { promise: Promise ->
             Permissions.askForPermissionsWithPermissionsManager(
                 appContext.permissions,
                 promise,
                 android.Manifest.permission.RECORD_AUDIO
             )
         }

        // Register events
        Events(
            ON_MIC_DATA_EVENT,
            ON_INPUT_VOLUME_LEVEL_EVENT,
            ON_OUTPUT_VOLUME_LEVEL_EVENT,
            ON_RECORDING_CHANGE_EVENT,
            ON_AUDIO_INTERRUPTION_EVENT,
            ON_PLAYBACK_QUEUE_EMPTY_EVENT,
            ON_VOICE_FOCUS_ERROR_EVENT
        )
    }

    // Creates the Quail processor once per app run. The model + processor are
    // cached across sessions (model load reads a ~5 MB file); a failed attempt
    // is not retried — the session falls back to the relay path instead.
    private fun ensureQuailProcessor(context: Context, licenseKey: String?) {
        if (quailProcessor != null || quailInitAttempted) return
        if (licenseKey.isNullOrEmpty()) return
        quailInitAttempted = true

        val modelPath = QuailProcessor.copyBundledModel(context)
        if (modelPath == null) {
            sendEvent(ON_VOICE_FOCUS_ERROR_EVENT, mapOf("data" to "aicmodel missing from assets"))
            return
        }
        val quail = try {
            QuailProcessor(licenseKey, modelPath)
        } catch (e: QuailProcessor.InitError) {
            sendEvent(ON_VOICE_FOCUS_ERROR_EVENT, mapOf("data" to "processor init failed: code=${e.code}"))
            return
        }
        quail.onError = { message ->
            sendEvent(ON_VOICE_FOCUS_ERROR_EVENT, mapOf("data" to message))
        }
        quailProcessor = quail
    }

    private fun setupCallbacks() {
        audioEngine?.apply {
            onMicDataCallback = { data ->
                sendEvent(ON_MIC_DATA_EVENT, bundleOf("data" to data))
            }
            onInputVolumeCallback = { level ->
                sendEvent(ON_INPUT_VOLUME_LEVEL_EVENT, bundleOf("data" to level))
            }
            onOutputVolumeCallback = { level ->
                sendEvent(ON_OUTPUT_VOLUME_LEVEL_EVENT, bundleOf("data" to level))
            }
            onAudioInterruptionCallback = { data ->
                sendEvent(ON_AUDIO_INTERRUPTION_EVENT, bundleOf("data" to data))
                sendEvent(ON_RECORDING_CHANGE_EVENT, bundleOf(
                    "data" to (audioEngine?.isRecording ?: false)
                ))
            }
            onPlaybackQueueEmptyCallback = {
                sendEvent(ON_PLAYBACK_QUEUE_EMPTY_EVENT, bundleOf())
            }
        }
    }
}