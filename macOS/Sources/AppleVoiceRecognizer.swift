import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech

/// Logs only fixed stage/reason names, random session IDs and elapsed milliseconds.
enum VoiceDiagnostics {
    static let fixtureEventDiagnostics = !(ProcessInfo.processInfo.environment["INKFLOW_VOICE_FIXTURE"] ?? "").isEmpty
    static func modifierArrival(keyCode: UInt16, flags: UInt) {
        guard fixtureEventDiagnostics else { return }
        logger.notice("stage=modifierArrival keyCode=\(keyCode) flags=\(flags)")
    }
    enum ShortcutKind: String { case rightShiftDown, rightShiftUp }
    static func shortcutArrival(_ kind: ShortcutKind, repeated: Bool, recognizedModifiers: Bool, delivering: Bool) {
        logger.notice("stage=shortcutArrival kind=\(kind.rawValue, privacy: .public) repeat=\(repeated) recognizedModifiers=\(recognizedModifiers) delivery=\(delivering)")
    }
    static func clientCommit() { logger.notice("stage=clientCommit") }
    enum FixtureStage: String { case start, preview, stop, cancel }
    static func fixture(_ stage: FixtureStage, mode: VoiceRecognitionFixture.Mode) {
        logger.notice("stage=fixture mode=\(mode.rawValue, privacy: .public) event=\(stage.rawValue, privacy: .public)")
    }
    enum StartRejection: String { case engine, busy, secure, client, bundle, foreground, selection, proxy, stale }
    /// One bounded timestamp per fixed reason; repeated shortcuts cannot flood the log.
    struct StartRejectionLimiter {
        private var last: [StartRejection: ContinuousClock.Instant] = [:]
        mutating func admit(_ reason: StartRejection, now: ContinuousClock.Instant = .now) -> Bool {
            if let previous = last[reason], previous.duration(to: now) < .seconds(5) { return false }
            last[reason] = now
            return true
        }
    }
    static func rejectStart(_ reason: StartRejection) {
        logger.notice("stage=startRejected reason=\(reason.rawValue, privacy: .public)")
    }
    enum Stage: String { case preparing, recording, stopping, finalized, cancelled, failed, tail, correcting, corrected, submitted, fallback }
    enum Reason: String { case none, unavailable, permission, audio, overflow, recognition, invalidRange, targetChanged, secureInput, editing, escape, deactivated, settingsChanged, engineChanged, correction }
    private static let logger = Logger(subsystem: "io.damao.inputmethod.inkflow", category: "voice")
    static func emit(_ stage: Stage, id: UUID, reason: Reason = .none, milliseconds: Int = 0, sequence: Int = 0) {
        logger.notice("session=\(id.uuidString, privacy: .public) stage=\(stage.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public) ms=\(milliseconds) sequence=\(sequence)")
    }
}

enum VoiceRecognitionError: Error { case unavailable, permission, audio, overflow, invalidRange }

/// The factory is deliberately outside MainActor. Its exact returned closure is exercised off-main.
/// A lock serializes converter access and stream termination; no borrowed tap buffer escapes.
final class VoiceAudioFeed: @unchecked Sendable {
    let stream: AsyncThrowingStream<AnalyzerInput, Error>
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var ended = false
    /// AVAudioConverter invokes this only during synchronous convert; the borrowed buffer never
    /// leaves that call. The separate lock also makes the Sendable callback's one-shot state safe.
    private final class Input: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private let lock = NSLock()
        private var supplied = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.lock(); defer { lock.unlock() }
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
    }


    init(input: AVAudioFormat, output: AVAudioFormat, capacity: Int = 64) throws {
        guard let converter = AVAudioConverter(from: input, to: output), input.sampleRate > 0,
              output.sampleRate > 0 else { throw VoiceRecognitionError.audio }
        self.converter = converter; self.outputFormat = output
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    }

    nonisolated func makeTap() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, _ in self.consume(buffer) }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        guard buffer.frameLength > 0, buffer.frameLength <= 8192 else {
            end(VoiceRecognitionError.audio); return
        }
        let frames = ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate) + 32
        guard frames <= 32768, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            end(VoiceRecognitionError.audio); return
        }
        let input = Input(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            input.take(state)
        }
        guard status != .error, error == nil else { end(VoiceRecognitionError.audio); return }
        if output.frameLength > 0 {
            switch continuation.yield(AnalyzerInput(buffer: output)) {
            case .enqueued: break
            case .dropped: end(VoiceRecognitionError.overflow)
            case .terminated: ended = true
            @unknown default: end(VoiceRecognitionError.audio)
            }
        }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        // Signal real end-of-stream to drain converter priming/trailing samples before ASR input ends.
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 32768) else {
                end(VoiceRecognitionError.audio); return
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream; return nil
            }
            guard status != .error, error == nil else { end(VoiceRecognitionError.audio); return }
            if output.frameLength > 0 {
                switch continuation.yield(AnalyzerInput(buffer: output)) {
                case .enqueued: break
                case .dropped: end(VoiceRecognitionError.overflow); return
                case .terminated: ended = true; return
                @unknown default: end(VoiceRecognitionError.audio); return
                }
            }
            if status == .endOfStream { end(nil); return }
        }
        end(VoiceRecognitionError.audio)
    }

    private func end(_ error: (any Error)?) {
        guard !ended else { return }; ended = true
        continuation.finish(throwing: error)
    }
}

/// Validates the ASR range contract before any segment can reach correction or insertion.
struct VoiceTranscriptAccumulator {
    private(set) var transcript = ""
    private var end: CMTime?
    private var volatile: [(CMTimeRange, String)] = []
    var volatileSuffix: String { volatile.map(\.1).joined() }
    mutating func appendFinal(_ text: String, range: CMTimeRange) throws {
        try validate(range)
        if let end, CMTimeCompare(range.start, end) < 0 { throw VoiceRecognitionError.invalidRange }
        guard transcript.utf16.count + text.utf16.count <= 16000 else { throw VoiceRecognitionError.overflow }
        transcript += text; end = CMTimeRangeGetEnd(range)
        volatile.removeAll { CMTimeCompare($0.0.start, end!) < 0 }
    }
    mutating func updateVolatile(_ text: String, range: CMTimeRange) throws -> String {
        try validate(range)
        if let end, CMTimeCompare(range.start, end) < 0 { throw VoiceRecognitionError.invalidRange }
        volatile.removeAll { CMTimeRangeGetIntersection($0.0, otherRange: range).duration.seconds > 0 || CMTimeCompare($0.0.start, range.start) == 0 }
        volatile.append((range, text)); volatile.sort { CMTimeCompare($0.0.start, $1.0.start) < 0 }
        let suffix = volatile.map(\.1).joined()
        guard volatile.count <= 512, transcript.utf16.count + suffix.utf16.count <= 16000 else { throw VoiceRecognitionError.overflow }
        return suffix
    }
    private func validate(_ range: CMTimeRange) throws {
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
              range.start.seconds >= 0, range.duration.seconds >= 0 else { throw VoiceRecognitionError.invalidRange }
    }
}

@MainActor
final class AppleVoiceRecognizer: VoiceRecognitionServing {
    struct Preparation: Sendable { let locale: Locale }
    struct Callbacks {
        var onFinal: (String) -> Void
        var onVolatile: (String) -> Void
        var onFinalized: (String) -> Void
        var onFailure: () -> Void
    }

    static func microphoneAllowed(requestPermission: Bool,
                                  status: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
                                  request: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) async -> Bool {
        if requestPermission { return await request() }
        return status() == .authorized
    }

    /// Resource preparation never records audio; automatic startup cannot request permission.
    private static func prepareResources(requestPermission: Bool) async throws -> Preparation {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else {
            throw VoiceRecognitionError.unavailable
        }
        let allowed = await microphoneAllowed(requestPermission: requestPermission)
        guard allowed else { throw VoiceRecognitionError.permission }
        try Task.checkCancellation()
        let module = makeTranscriber(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw VoiceRecognitionError.unavailable }
        return Preparation(locale: locale)
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults, .alternativeTranscriptions],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }
    private var preparation: Preparation?
    var isReady: Bool { preparation != nil }
    init(preparation: Preparation? = nil) { self.preparation = preparation }
    func prepare(requestPermission: Bool) async throws {
        preparation = try await Self.prepareResources(requestPermission: requestPermission)
    }
    private var id: UUID?

    private var stopped = false
    private var engine: AVAudioEngine?
    private var feed: VoiceAudioFeed?
    private var analyzer: SpeechAnalyzer?
    private var task: Task<Void, Never>?
    private var resultTask: Task<Void, Error>?
    private var callbacks: Callbacks?
    private var accumulator = VoiceTranscriptAccumulator()
    private var started = ContinuousClock.now

    func start(id token: UUID, snapshot: VoiceLexiconSnapshot, callbacks: Callbacks) {
        cancel()
        id = token; stopped = false; self.callbacks = callbacks
        accumulator = .init(); started = .now
        VoiceDiagnostics.emit(.preparing, id: token)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let preparation = self.preparation else { throw VoiceRecognitionError.unavailable }
                try await self.run(id: token, preparation: preparation, snapshot: snapshot)
            }
            catch {
                guard self.id == token else { return }
                self.fail(id: token, error: error)
            }
        }
    }

    func stop(id token: UUID) {
        guard id == token, !stopped else { return }
        stopped = true
        VoiceDiagnostics.emit(.stopping, id: token)
        stopAudio()
        feed?.finish()
    }

    func cancel() {
        guard let token = id else { return }
        id = nil; callbacks = nil
        stopAudio(); feed?.finish(); feed = nil
        task?.cancel(); task = nil; resultTask?.cancel(); resultTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        VoiceDiagnostics.emit(.cancelled, id: token)
    }

    private func run(id token: UUID, preparation: Preparation, snapshot: VoiceLexiconSnapshot) async throws {
        guard id == token else { return }
        if stopped { finish(id: token); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw VoiceRecognitionError.permission }
        let module = Self.makeTranscriber(preparation.locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw VoiceRecognitionError.unavailable
        }
        guard id == token else { return }
        try Task.checkCancellation()
        try await analyzer.prepareToAnalyze(in: format)
        guard id == token else { return }
        try Task.checkCancellation()
        if stopped { await analyzer.cancelAndFinishNow(); finish(id: token); return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let natural = input.outputFormat(forBus: 0)
        let feed = try VoiceAudioFeed(input: natural, output: format)
        self.feed = feed; self.engine = engine
        resultTask = Task { [weak self] in
            do {
            for try await result in module.results {
                try Task.checkCancellation()
                guard let self, self.id == token else { return }
                let alternatives = Array(result.alternatives.prefix(16)).map { String($0.characters) }
                let primary = String(result.text.characters)
                let choices = alternatives.isEmpty ? [primary] : alternatives
                guard choices.allSatisfy({ $0.utf16.count <= 16000 }) else { throw VoiceRecognitionError.overflow }
                if result.isFinal {
                    let prefix = String(self.accumulator.transcript.suffix(8))
                    let ranked = await Task.detached(priority: .userInitiated) {
                        VoiceAlternativeReranker.select([choices], snapshot: snapshot, fixedPrefix: prefix)
                    }.value
                    guard self.id == token, !Task.isCancelled else { return }
                    try self.accumulator.appendFinal(ranked, range: result.range)
                    self.callbacks?.onFinal(ranked)
                    self.callbacks?.onVolatile(self.accumulator.volatileSuffix)
                } else {
                    let suffix = try self.accumulator.updateVolatile(primary, range: result.range)
                    self.callbacks?.onVolatile(suffix)
                }
            }
            } catch {
                if let self, self.id == token { self.fail(id: token, error: error) }
                throw error
            }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: natural, block: feed.makeTap())
        engine.prepare()
        guard id == token else { feed.finish(); await analyzer.cancelAndFinishNow(); return }
        if stopped {
            stopAudio(); feed.finish(); await analyzer.cancelAndFinishNow()
            finish(id: token); return
        }
        try engine.start()
        VoiceDiagnostics.emit(.recording, id: token)
        // start returns once analysis has begun; explicit stop ends its input stream.
        try await analyzer.start(inputSequence: feed.stream)
        guard id == token else { return }
        // Wait for stop without relying on start() return semantics.
        while !stopped {
            try await Task.sleep(for: .milliseconds(20))
            guard id == token else { return }
        }
        let finalResults = resultTask
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await finalResults?.value
        guard id == token else { return }
        finish(id: token)
    }

    private func stopAudio() {
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
    }
    private func finish(id token: UUID) {
        guard id == token else { return }
        let callback = callbacks?.onFinalized; let transcript = accumulator.transcript
        id = nil; callbacks = nil; stopAudio(); feed = nil; analyzer = nil
        task = nil; resultTask = nil
        VoiceDiagnostics.emit(.finalized, id: token, milliseconds: elapsed())
        callback?(transcript)
    }
    private func fail(id token: UUID, error: any Error) {
        guard id == token else { return }
        let callback = callbacks?.onFailure
        let reason: VoiceDiagnostics.Reason = switch error as? VoiceRecognitionError {
        case .overflow: .overflow
        case .invalidRange: .invalidRange
        case .permission: .permission
        case .unavailable: .unavailable
        case .audio: .audio
        case nil: .recognition
        }
        cancel()
        VoiceDiagnostics.emit(.failed, id: token, reason: reason, milliseconds: elapsed())
        callback?()
    }
    private func elapsed() -> Int {
        let duration = started.duration(to: .now).components
        return Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
    }
}

/// Explicit process-only reproduction source. It never opens audio or network resources.
@MainActor
final class VoiceRecognitionFixture: VoiceRecognitionServing {
    enum Mode: String { case final, preview }
    static let configured = Mode(rawValue: ProcessInfo.processInfo.environment["INKFLOW_VOICE_FIXTURE"] ?? "")
    let isReady = true
    private let mode: Mode
    private let sleep: (Duration) async throws -> Void
    private var token: UUID?
    private var callbacks: AppleVoiceRecognizer.Callbacks?
    private var task: Task<Void, Never>?
    private var stopped = false

    init(mode: Mode, sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.mode = mode; self.sleep = sleep
    }
    func prepare(requestPermission: Bool) async throws {}
    func start(id: UUID, snapshot: VoiceLexiconSnapshot, callbacks: AppleVoiceRecognizer.Callbacks) {
        cancel()
        token = id; self.callbacks = callbacks; stopped = false
        VoiceDiagnostics.fixture(.start, mode: mode)
        guard mode == .preview else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            for text in ["语音测", "语音测试"] {
                do { try await self.sleep(.seconds(1)) } catch { return }
                guard !Task.isCancelled, self.token == id, !self.stopped else { return }
                VoiceDiagnostics.fixture(.preview, mode: self.mode)
                self.callbacks?.onVolatile(text)
            }
        }
    }
    func stop(id: UUID) {
        guard token == id, !stopped, let callbacks else { return }
        stopped = true; task?.cancel(); task = nil
        VoiceDiagnostics.fixture(.stop, mode: mode)
        if mode == .preview { callbacks.onFinal("语音测试") }
        guard token == id else { return }
        token = nil; self.callbacks = nil
        callbacks.onFinalized("语音测试")
    }
    func cancel() {
        if token != nil { VoiceDiagnostics.fixture(.cancel, mode: mode) }
        token = nil; callbacks = nil; task?.cancel(); task = nil
    }
}

@MainActor
protocol VoiceRecognitionServing: AnyObject {
    var isReady: Bool { get }
    func prepare(requestPermission: Bool) async throws
    func start(id: UUID, snapshot: VoiceLexiconSnapshot, callbacks: AppleVoiceRecognizer.Callbacks)
    func stop(id: UUID)
    func cancel()
}
