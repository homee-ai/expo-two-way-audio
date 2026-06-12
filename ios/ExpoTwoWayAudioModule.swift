import ExpoModulesCore

let ON_MIC_DATA_EVENT_NAME = "onMicrophoneData"
let ON_INPUT_VOLUME_LEVEL_EVENT_NAME = "onInputVolumeLevelData"
let ON_OUTPUT_VOLUME_LEVEL_EVENT_NAME = "onOutputVolumeLevelData"
let ON_RECORDING_CHANGE_EVENT_NAME = "onRecordingChange"
let ON_AUDIO_INTERRUPTION_EVENT_NAME = "onAudioInterruption"
let ON_PLAYBACK_QUEUE_EMPTY_EVENT_NAME = "onPlaybackQueueEmpty"
let ON_VOICE_FOCUS_ERROR_EVENT_NAME = "onVoiceFocusError"

public class ExpoTwoWayAudioModule: Module {
    private var audioEngine: AudioEngine?
    private var quailProcessor: QuailProcessor?
    private var quailInitAttempted = false
    public func definition() -> ModuleDefinition {
        Name("ExpoTwoWayAudio")

        OnCreate {
            let permissionsManager = self.appContext?.permissions
            EXPermissionsMethodsDelegate.register(
                [
                    MicrophonePermissionRequester()
                ],
                withPermissionsManager: permissionsManager
            )

        }

        AsyncFunction("initialize") { (voiceFocusLicenseKey: String?) -> Bool in
            do {
                // Create the processor before the early return so a keyed
                // initialize after a keyless one still warms the cache.
                // Injection still only happens when a fresh engine is created
                // below — an already-running engine keeps its current pipeline.
                self.ensureQuailProcessor(licenseKey: voiceFocusLicenseKey)
                if self.audioEngine != nil {
                    return true
                }
                self.audioEngine = try AudioEngine()
                // Only inject the processor when its rate matches the engine's
                // mic tap format; otherwise enhancement would distort the audio.
                // The engine was just created, so the tap isn't delivering
                // buffers yet and reset() is safe to call.
                if let engine = self.audioEngine, let quail = self.quailProcessor {
                    if QuailProcessor.sampleRate == UInt32(engine.voiceIOFormat.sampleRate) {
                        engine.voiceFocus = quail
                        quail.reset()
                    } else {
                        self.sendEvent(ON_VOICE_FOCUS_ERROR_EVENT_NAME, ["data": "sample-rate mismatch: engine \(engine.voiceIOFormat.sampleRate) vs processor \(QuailProcessor.sampleRate)"])
                    }
                }
                self.setupMicrophoneCallback()
                self.setupInputAudioLevelCallback()
                self.setupOutputAudioLevelCallback()
                self.setupAudioInterruptionCallback()
                self.setupPlaybackQueueEmptyCallback()
                return true
            } catch {
                print("Failed to initialize AudioEngine: \(error)")
                return false
            }
        }

        Function("isVoiceFocusAvailable") { () -> Bool in
            // Reads the engine's injected reference, not the cached processor:
            // "available" means wired into the live pipeline. The cache can hold
            // a working processor that was skipped on sample-rate mismatch.
            return self.audioEngine?.voiceFocus?.isAvailable ?? false
        }

        Function("setVoiceFocusEnabled") { (enabled: Bool) in
            self.quailProcessor?.setEnabled(enabled)
        }

        Function("isRecording") { () -> Bool in
            guard let audioEngine = self.audioEngine else {
                print("AudioEngine not initialized")
                return false
            }
            return audioEngine.isRecording
        }

        Function("toggleRecording") { (val: Bool) -> Bool in
            guard let audioEngine = self.audioEngine else {
                print("AudioEngine not initialized")
                return false
            }
            let isRecording = audioEngine.toggleRecording(val)
            self.sendEvent(
                ON_RECORDING_CHANGE_EVENT_NAME,
                [
                    "data": isRecording
                ])
            return isRecording
        }

        Function("getMicrophoneModeIOS") { () -> String in
            if #available(iOS 15.0, *) {
                let mode = AVCaptureDevice.preferredMicrophoneMode.rawValue
                var micMode = ""

                switch mode {
                case 1:
                    micMode = MicrophoneMode.wideSpectrum.rawValue
                case 2:
                    micMode = MicrophoneMode.voiceIsolation.rawValue
                default:
                    micMode = MicrophoneMode.standard.rawValue
                }
                return micMode
            }
            print("Please update your ios")

            return ""
        }

        Function("setMicrophoneModeIOS") {
            if #available(iOS 15, *) {
                if AVCaptureDevice.preferredMicrophoneMode != .voiceIsolation {
                    AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                }
            } else {
                print("This code only runs on iOS 14 and lower")
            }
        }

        Function("tearDown") {
            self.audioEngine?.tearDown()
            self.audioEngine = nil
        }

        Function("restart") {
            self.audioEngine?.resumeRecordingAndPlayer()
            self.sendEvent(
                ON_RECORDING_CHANGE_EVENT_NAME,
                [
                    "data": audioEngine?.isRecording
                ])

        }

        Function("playPCMData") { (pcmData: Data) in
            self.audioEngine?.playPCMData(pcmData)
        }

        Function("flushPlayback") {
            self.audioEngine?.flushPlayback()
        }

        Function("bypassVoiceProcessing") { (bypass: Bool) in
            self.audioEngine?.bypassVoiceProcessing(bypass)
        }

        Function("isPlaying") { () -> Bool in
            return self.audioEngine?.isPlaying ?? false
        }

        AsyncFunction("getMicrophonePermissionsAsync") { (promise: Promise) in
            EXPermissionsMethodsDelegate.getPermissionWithPermissionsManager(
                self.appContext?.permissions,
                withRequester: MicrophonePermissionRequester.self,
                resolve: promise.resolver,
                reject: promise.legacyRejecter
            )
        }

        AsyncFunction("requestMicrophonePermissionsAsync") { (promise: Promise) in
            EXPermissionsMethodsDelegate.askForPermission(
                withPermissionsManager: self.appContext?.permissions,
                withRequester: MicrophonePermissionRequester.self,
                resolve: promise.resolver,
                reject: promise.legacyRejecter
            )
        }

        // Define the events that can be emitted
        Events([
            ON_MIC_DATA_EVENT_NAME,
            ON_INPUT_VOLUME_LEVEL_EVENT_NAME,
            ON_OUTPUT_VOLUME_LEVEL_EVENT_NAME,
            ON_RECORDING_CHANGE_EVENT_NAME,
            ON_AUDIO_INTERRUPTION_EVENT_NAME,
            ON_PLAYBACK_QUEUE_EMPTY_EVENT_NAME,
            ON_VOICE_FOCUS_ERROR_EVENT_NAME,
        ])
    }

    // Creates the Quail processor once per app run. The model + processor are
    // cached across sessions (model load reads a ~5 MB file); a failed attempt
    // is not retried — the session falls back to the relay path instead.
    private func ensureQuailProcessor(licenseKey: String?) {
        guard quailProcessor == nil, !quailInitAttempted else { return }
        guard let key = licenseKey, !key.isEmpty else { return }
        quailInitAttempted = true

        guard let modelPath = QuailProcessor.bundledModelPath() else {
            self.sendEvent(ON_VOICE_FOCUS_ERROR_EVENT_NAME, ["data": "aicmodel missing from bundle"])
            return
        }
        let quail: QuailProcessor
        do {
            quail = try QuailProcessor(licenseKey: key, modelPath: modelPath)
        } catch {
            // `\(error)` renders InitError's CustomStringConvertible description
            // (stage + SDK error code).
            self.sendEvent(ON_VOICE_FOCUS_ERROR_EVENT_NAME, ["data": "processor init failed: \(error)"])
            return
        }
        quail.onError = { [weak self] message in
            self?.sendEvent(ON_VOICE_FOCUS_ERROR_EVENT_NAME, ["data": message])
        }
        quailProcessor = quail
    }

    private func setupMicrophoneCallback() {
        audioEngine?.onMicDataCallback = { [weak self] data in
            self?.sendEvent(
                ON_MIC_DATA_EVENT_NAME,
                [
                    "data": data
                ])
        }
    }

    private func setupInputAudioLevelCallback() {
        audioEngine?.onInputVolumeCallback = { [weak self] level in
            self?.sendEvent(
                ON_INPUT_VOLUME_LEVEL_EVENT_NAME,
                [
                    "data": level
                ])
        }
    }

    private func setupOutputAudioLevelCallback() {
        audioEngine?.onOutputVolumeCallback = { [weak self] level in
            self?.sendEvent(
                ON_OUTPUT_VOLUME_LEVEL_EVENT_NAME,
                [
                    "data": level
                ])
        }
    }

    private func setupAudioInterruptionCallback() {
        audioEngine?.onAudioInterruptionCallback = { [weak self] data in
            self?.sendEvent(
                ON_AUDIO_INTERRUPTION_EVENT_NAME,
                [
                    "data": data
                ])
            self?.sendEvent(
                ON_RECORDING_CHANGE_EVENT_NAME,
                [
                    "data": self?.audioEngine?.isRecording
                ])
        }
    }

    private func setupPlaybackQueueEmptyCallback() {
        audioEngine?.onPlaybackQueueEmptyCallback = { [weak self] in
            self?.sendEvent(ON_PLAYBACK_QUEUE_EMPTY_EVENT_NAME, [:])
        }
    }

    enum MicrophoneMode: String, Enumerable {
        case standard
        case voiceIsolation
        case wideSpectrum
    }
}
