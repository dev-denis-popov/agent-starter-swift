// High-level, optional wake-word engine.
//
// Captures the mic with a private `AVAudioEngine` in `.measurement` mode
// (near-raw audio = reliable detection) and runs the bundled "hey_livekit"
// classifier. On detection, `onWake` fires on the main actor — the host app
// decides what to do (e.g. start a LiveKit session). This type has no app
// dependencies, so the whole feature lives in (and ships with) this package.
//
// Note on isolation: hosts building with `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor` would otherwise have the realtime audio callback inferred as
// main-actor isolated and trip a `dispatch_assert_queue` crash when
// `AVAudioEngine` runs it on its render thread; so the `@Published` UI state
// stays `@MainActor` while the audio tap + inference path are explicitly
// `nonisolated` (shared buffers `nonisolated(unsafe)`, guarded by `ringLock`).
//
// Licensed under the Apache License, Version 2.0.

@preconcurrency import AVFoundation
import Combine
import Foundation

public final class WakewordEngine: ObservableObject, @unchecked Sendable {

    // MARK: - Published state (mutated on MainActor)

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?

    /// Called once, on the main actor, on the rising edge of a detection.
    public var onWake: (() -> Void)?

    // MARK: - Tuning

    private let triggerThreshold: Float = 0.75
    private let predictInterval: CFAbsoluteTime = 0.05
    private let windowSeconds: Double = 2.0

    // MARK: - Model

    private let classifierURLs: [URL]
    nonisolated(unsafe) private var model: WakeWordModel?

    // MARK: - Audio capture

    private var engine: AVAudioEngine?
    private let workQueue = DispatchQueue(label: "io.unitcore.wakeword.predict", qos: .userInitiated)

    // Shared between the realtime audio thread, the inference queue, and the
    // main actor — all access is serialized through `ringLock`.
    private let ringLock = NSLock()
    nonisolated(unsafe) private var ring: [Int16] = []
    nonisolated(unsafe) private var writeIdx = 0
    nonisolated(unsafe) private var samplesWritten = 0
    nonisolated(unsafe) private var lastPredictAt: CFAbsoluteTime = 0
    nonisolated(unsafe) private var predictInFlight = false
    nonisolated(unsafe) private var loggedFirstChunk = false

    // MARK: - Init

    public init() throws {
        guard let url = Bundle.module.url(forResource: "hey_livekit", withExtension: "onnx") else {
            throw NSError(
                domain: "WakewordEngine",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "hey_livekit.onnx classifier not found in WakeWord package bundle"]
            )
        }
        self.classifierURLs = [url]
    }

    // MARK: - Public API

    @MainActor
    public func startListening() {
        guard !isRunning else { return }
        Task { await self.startAfterAuth() }
    }

    /// Stop listening and release the mic.
    /// - Parameter handoff: pass `true` when another audio client (e.g. LiveKit)
    ///   is about to take over. The engine is stopped but the `AVAudioSession`
    ///   is **left active** so the next client can reconfigure it without a
    ///   deactivate/activate cycle that can stall WebRTC's audio unit. Pass
    ///   `false` (default) to fully release the session.
    @MainActor
    public func stopListening(handoff: Bool = false) {
        // Guard so a second call (e.g. StartView.onDisappear right after a
        // wake-triggered handoff) does not deactivate the audio session that
        // LiveKit has just taken over.
        guard isRunning else { return }
        stopInternal(deactivateSession: !handoff)
    }

    // MARK: - Permission + start

    @MainActor
    private func startAfterAuth() async {
        let granted = await requestMicrophonePermission()
        guard granted else {
            lastError = "Microphone permission denied. Enable it in Settings → Privacy → Microphone."
            print("[WAKEWORD] mic permission denied")
            return
        }
        do {
            // Build the model off the main thread (CoreML session compilation).
            if model == nil {
                model = try await buildModel()
            }
            try start()
            lastError = nil
        } catch {
            print("[WAKEWORD] start failed: \(error)")
            lastError = "Wake-word start failed: \(error.localizedDescription)"
            stopInternal()
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, macOS 14.0, *) {
            if AVAudioApplication.shared.recordPermission == .granted { return true }
            return await AVAudioApplication.requestRecordPermission()
        } else {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            if session.recordPermission == .granted { return true }
            return await withCheckedContinuation { cont in
                session.requestRecordPermission { cont.resume(returning: $0) }
            }
            #else
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined:
                return await withCheckedContinuation { cont in
                    AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
                }
            default: return false
            }
            #endif
        }
    }

    // MARK: - Start / Stop

    @MainActor
    private func start() throws {
        try configureAudioSession()

        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(
                domain: "WakewordEngine",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Input has no valid sample rate (is a microphone connected?)"]
            )
        }
        guard model != nil else {
            throw NSError(
                domain: "WakewordEngine",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Wake-word model was not initialized"]
            )
        }

        // Model runs at 16 kHz; the converter below resamples the hardware stream.
        let modelRate = Double(WakeWordModel.modelSampleRate)
        resetRing(size: max(Int(modelRate * windowSeconds), 1))
        loggedFirstChunk = false

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: modelRate,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(domain: "WakewordEngine", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create target Int16 format"])
        }
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw NSError(domain: "WakewordEngine", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create AVAudioConverter"])
        }

        installTap(on: input, format: hwFormat, converter: converter, targetFormat: targetFormat)

        engine.prepare()
        try engine.start()
        isRunning = true
        print("[WAKEWORD] listening (AVAudioEngine, hwRate=\(hwFormat.sampleRate))")
    }

    @MainActor
    private func stopInternal(deactivateSession: Bool = true) {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        #if os(iOS)
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        #endif

        clearRing()
        isRunning = false
    }

    @MainActor
    private func configureAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true, options: [])
        #endif
    }

    // MARK: - Model build (off main thread)

    private func buildModel() async throws -> WakeWordModel {
        let urls = classifierURLs
        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                do {
                    let model = try WakeWordModel(
                        models: urls,
                        sampleRate: WakeWordModel.modelSampleRate,
                        executionProvider: .coreML
                    )
                    continuation.resume(returning: model)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Audio tap (nonisolated, runs on the realtime audio thread)

    nonisolated private func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleInput(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }
    }

    nonisolated private func handleInput(
        buffer inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: inputBuffer.frameCapacity
        ) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil,
              let channelData = outBuffer.int16ChannelData else { return }

        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0 else { return }

        if !loggedFirstChunk {
            loggedFirstChunk = true
            print("[WAKEWORD] first audio chunk: \(frameCount) samples")
        }

        let shouldRun = appendAndCheck(samples: channelData[0], count: frameCount)
        if shouldRun, let snapshot = snapshotRing() {
            workQueue.async { [weak self] in
                self?.runPredict(snapshot: snapshot)
            }
        }
    }

    // MARK: - Ring buffer (nonisolated, guarded by ringLock)

    nonisolated private func resetRing(size: Int) {
        ringLock.lock()
        ring = [Int16](repeating: 0, count: size)
        writeIdx = 0
        samplesWritten = 0
        predictInFlight = false
        lastPredictAt = 0
        ringLock.unlock()
    }

    nonisolated private func clearRing() {
        ringLock.lock()
        ring = []
        writeIdx = 0
        samplesWritten = 0
        predictInFlight = false
        lastPredictAt = 0
        ringLock.unlock()
    }

    nonisolated private func appendAndCheck(samples: UnsafePointer<Int16>, count: Int) -> Bool {
        ringLock.lock()
        defer { ringLock.unlock() }

        let size = ring.count
        guard size > 0 else { return false }
        var idx = writeIdx
        for i in 0 ..< count {
            ring[idx] = samples[i]
            idx += 1
            if idx >= size { idx = 0 }
        }
        writeIdx = idx
        samplesWritten = min(samplesWritten + count, size)

        guard samplesWritten >= size else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        guard (now - lastPredictAt) >= predictInterval else { return false }
        guard !predictInFlight else { return false }
        lastPredictAt = now
        predictInFlight = true
        return true
    }

    nonisolated private func snapshotRing() -> [Int16]? {
        ringLock.lock()
        defer { ringLock.unlock() }
        let size = ring.count
        guard samplesWritten >= size, size > 0 else { return nil }
        var out = [Int16](repeating: 0, count: size)
        let tail = size - writeIdx
        out.withUnsafeMutableBufferPointer { dst in
            ring.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                dstBase.update(from: srcBase + writeIdx, count: tail)
                if writeIdx > 0 {
                    (dstBase + tail).update(from: srcBase, count: writeIdx)
                }
            }
        }
        return out
    }

    nonisolated private func runPredict(snapshot: [Int16]) {
        defer {
            ringLock.lock()
            predictInFlight = false
            ringLock.unlock()
        }
        guard let model else { return }
        do {
            let scores = try model.predict(snapshot)
            let maxScore = scores.values.max() ?? 0
            if maxScore >= 0.3 {
                print("[WAKEWORD] score=\(maxScore)")
            }
            if maxScore >= triggerThreshold {
                Task { @MainActor [weak self] in self?.fireWake() }
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.lastError = "predict failed: \(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func fireWake() {
        guard isRunning else { return }
        onWake?()
    }
}
