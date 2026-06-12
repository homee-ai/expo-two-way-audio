import Foundation
import AicSdk

/// Wraps an aic-sdk Quail speech-enhancement processor for the outgoing mic path.
///
/// Threading contract: `process(_:count:)` must only ever be called from the
/// audio tap thread (the SDK's process call is real-time safe but not
/// thread-safe). `setEnabled` may be called from any thread (the SDK context
/// is thread-safe). `reset()` must only be called while the tap is **not**
/// delivering buffers (i.e. after the engine is stopped or recording is off),
/// because it mutates the same `pending` accumulator that `process(_:count:)`
/// uses — concurrent mutation of a Swift Array is undefined behaviour.
final class QuailProcessor {
    static let sampleRate: UInt32 = 24000

    private var model: OpaquePointer?
    private var processor: OpaquePointer?
    private var context: OpaquePointer?
    private(set) var optimalFrameCount: Int = 0

    // Mic samples accumulate here until a full model frame is available.
    private var pending: [Float] = []
    // Latched on the first process() error within a session; cleared by reset() so each
    // new session gets at most one retry (and at most one onError event per session).
    // Written on the tap queue; read from other threads via `isAvailable`. A torn Bool
    // read is benign on arm64 and acceptable here — revisit under Swift 6 strict concurrency.
    private(set) var hasFailed = false
    var onError: ((String) -> Void)?

    var isAvailable: Bool { processor != nil && !hasFailed }

    /// Locates the bundled .aicmodel inside the AicModels resource bundle
    /// (copied into the app bundle because the pod is a static framework).
    static func bundledModelPath() -> String? {
        let candidates = [
            Bundle.main.url(forResource: "AicModels", withExtension: "bundle"),
            Bundle(for: QuailProcessor.self).url(forResource: "AicModels", withExtension: "bundle"),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url),
               let path = bundle.paths(forResourcesOfType: "aicmodel", inDirectory: nil).first {
                // Enumerate instead of hardcoding the filename: the vendor script controls
                // which single .aicmodel ships, keeping the two automatically in sync.
                return path
            }
        }
        return nil
    }

    init?(licenseKey: String, modelPath: String) {
        var modelHandle: OpaquePointer?
        var rc = aic_model_create_from_file(&modelHandle, modelPath)
        guard rc == AIC_ERROR_CODE_SUCCESS, let loadedModel = modelHandle else {
            NSLog("[QuailProcessor] model load failed: \(rc)")
            return nil
        }
        model = loadedModel

        var frames: Int = 0
        rc = aic_model_get_optimal_num_frames(loadedModel, Self.sampleRate, &frames)
        guard rc == AIC_ERROR_CODE_SUCCESS, frames > 0 else {
            NSLog("[QuailProcessor] optimal frame query failed: \(rc)")
            aic_model_destroy(loadedModel)
            model = nil
            return nil
        }
        optimalFrameCount = frames

        var proc: OpaquePointer?
        rc = aic_processor_create(&proc, loadedModel, licenseKey, nil)
        guard rc == AIC_ERROR_CODE_SUCCESS, let createdProc = proc else {
            NSLog("[QuailProcessor] processor create failed: \(rc)")
            aic_model_destroy(loadedModel)
            model = nil
            return nil
        }
        processor = createdProc

        rc = aic_processor_initialize(createdProc, Self.sampleRate, 1, frames, false)
        guard rc == AIC_ERROR_CODE_SUCCESS else {
            NSLog("[QuailProcessor] processor initialize failed: \(rc)")
            aic_processor_destroy(createdProc)
            aic_model_destroy(loadedModel)
            processor = nil
            model = nil
            return nil
        }

        var ctx: OpaquePointer?
        rc = aic_processor_context_create(&ctx, createdProc)
        guard rc == AIC_ERROR_CODE_SUCCESS, let createdCtx = ctx else {
            NSLog("[QuailProcessor] context create failed: \(rc)")
            aic_processor_destroy(createdProc)
            aic_model_destroy(loadedModel)
            processor = nil
            model = nil
            return nil
        }
        context = createdCtx

        pending.reserveCapacity(optimalFrameCount * 4)
    }

    deinit {
        aic_processor_context_destroy(context)
        aic_processor_destroy(processor)
        aic_model_destroy(model)
    }

    /// Enhancement toggle. Disabled uses the SDK's latency-compensated bypass
    /// (output delay unchanged), so flipping mid-stream produces no clicks.
    func setEnabled(_ enabled: Bool) {
        guard let context else { return }
        aic_processor_context_set_parameter(context, AIC_PROCESSOR_PARAMETER_BYPASS, enabled ? 0.0 : 1.0)
    }

    /// Clears SDK state and the local accumulator. Call between sessions and
    /// after audio interruptions so stale audio doesn't color the next frames.
    /// Must only be called while the audio tap is not delivering buffers (see
    /// class-level threading contract). Also resets `hasFailed` so the new
    /// session gets at most one enhancement-error retry.
    func reset() {
        if let context {
            aic_processor_context_reset(context)
        }
        pending.removeAll(keepingCapacity: true)
        hasFailed = false
    }

    /// Feeds raw mic samples; returns the enhanced samples that are ready (a
    /// multiple of the model frame size — possibly empty while accumulating).
    /// On the first SDK error this latches `hasFailed`, reports via `onError`,
    /// and returns the failing chunk as-is (possibly partially processed by the
    /// SDK) plus the remaining buffered input, so no audio is lost.
    func process(_ samples: UnsafePointer<Float>, count: Int) -> [Float] {
        if hasFailed {
            return Array(UnsafeBufferPointer(start: samples, count: count))
        }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))

        var output: [Float] = []
        // Per-callback Array allocations below are deliberate: the tap runs on a
        // non-realtime dispatch queue so heap allocation is safe. Revisit only if
        // this moves to a realtime (AudioUnit render) thread.
        while pending.count >= optimalFrameCount {
            var chunk = Array(pending.prefix(optimalFrameCount))
            pending.removeFirst(optimalFrameCount)

            let rc = chunk.withUnsafeMutableBufferPointer { buf -> AicErrorCode in
                var channel: UnsafeMutablePointer<Float>? = buf.baseAddress
                return withUnsafeMutablePointer(to: &channel) { planar in
                    aic_processor_process_planar(processor, planar, 1, optimalFrameCount)
                }
            }
            guard rc == AIC_ERROR_CODE_SUCCESS else {
                hasFailed = true
                let leftover = pending
                pending.removeAll(keepingCapacity: false)
                onError?("aic_processor_process_planar failed: \(rc)")
                return output + chunk + leftover
            }
            output.append(contentsOf: chunk)
        }
        return output
    }
}
