import Foundation

/// Owns one ephemeral transcript. ASR adapters must deliver each final segment once, in order,
/// then call finalized only after their result stream and audio finalization have both ended.
@MainActor
final class VoiceSession {
    struct Limits: Sendable {
        var recording: Duration = .seconds(120)
        var tail: Duration = .seconds(10)
        var correctionWait: Duration = .seconds(20)
        var segments = 512
        var textUTF16 = 16_000
    }
    enum Failure: Equatable { case boundExceeded, recognitionFailed, finalizationTimedOut }
    enum Outcome: Equatable {
        case completed(String, usedRawFallback: Bool)
        case cancelled
        case failed(Failure)
    }
    typealias Correction = @MainActor (String) async throws -> String
    private let limits: Limits
    private let correct: Correction?
    private let onPreview: (String) -> Void
    private let onRequestFinalize: (UUID) -> Void
    private let onFinish: (Outcome) -> Void
    private(set) var id: UUID?
    private var stopped = false
    private var finalTranscript: String?
    private var segments: [String] = []
    private var corrected: [String] = []
    private var rawFallback = false
    private var worker: Task<Void, Never>?
    private var recordingTimer: Task<Void, Never>?
    private var tailTimer: Task<Void, Never>?
    private var correctionTimer: Task<Void, Never>?

    init(limits: Limits = .init(), correct: Correction? = nil,
         onPreview: @escaping (String) -> Void,
         onRequestFinalize: @escaping (UUID) -> Void,
         onFinish: @escaping (Outcome) -> Void) {
        self.limits = limits; self.correct = correct
        self.onPreview = onPreview; self.onRequestFinalize = onRequestFinalize; self.onFinish = onFinish
    }

    @discardableResult func start() -> UUID {
        if let id { cancel(id: id) }
        // A completion callback may synchronously start the replacement session.
        if let id { return id }
        let token = UUID()
        id = token; stopped = false; finalTranscript = nil
        segments = []; corrected = []; rawFallback = false
        recordingTimer = timer(after: limits.recording, id: token) { session in
            session.finish(.failed(.boundExceeded))
        }
        return token
    }

    /// The volatile string is only the unfinished suffix, not the full transcript.
    func receiveVolatile(_ text: String, id token: UUID) {
        guard id == token, finalTranscript == nil else { return }
        let preview = segments.joined() + text
        guard preview.utf16.count <= limits.textUTF16 else { finish(.failed(.boundExceeded)); return }
        onPreview(preview)
    }

    func receiveFinal(_ text: String, id token: UUID) {
        guard id == token, finalTranscript == nil, !text.isEmpty else { return }
        guard segments.count < limits.segments,
              segments.joined().utf16.count + text.utf16.count <= limits.textUTF16 else {
            finish(.failed(.boundExceeded)); return
        }
        segments.append(text)
        onPreview(segments.joined())
        launchWorker(id: token)
    }

    func stop(id token: UUID) {
        guard id == token, !stopped else { return }
        stopped = true
        recordingTimer?.cancel(); recordingTimer = nil
        tailTimer = timer(after: limits.tail, id: token) { $0.finish(.failed(.finalizationTimedOut)) }
        if correct != nil {
            correctionTimer = timer(after: limits.correctionWait, id: token) { session in
                session.useRawFallback()
                session.completeIfReady()
            }
        }
        onRequestFinalize(token)
    }

    func finalized(transcript: String, id token: UUID) {
        guard id == token, stopped, finalTranscript == nil else { return }
        guard transcript.utf16.count <= limits.textUTF16 else { finish(.failed(.boundExceeded)); return }
        finalTranscript = transcript
        tailTimer?.cancel(); tailTimer = nil
        // An adapter mismatch must never cause corrected segments to omit recognized words.
        if transcript != segments.joined() { useRawFallback() }
        completeIfReady()
    }

    func recognitionFailed(id token: UUID) {
        guard id == token else { return }
        finish(.failed(.recognitionFailed))
    }

    func cancel(id token: UUID) {
        guard id == token else { return }
        finish(.cancelled)
    }

    private func launchWorker(id token: UUID) {
        guard id == token, worker == nil, !rawFallback, let correct else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while self.id == token, !self.rawFallback, self.corrected.count < self.segments.count {
                let index = self.corrected.count
                do {
                    let text = try await correct(self.segments[index])
                    try Task.checkCancellation()
                    guard self.id == token, !self.rawFallback else { return }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          self.corrected.joined().utf16.count + text.utf16.count <= self.limits.textUTF16 else {
                        self.useRawFallback(); break
                    }
                    self.corrected.append(text)
                } catch {
                    guard self.id == token, !Task.isCancelled else { return }
                    self.useRawFallback(); break
                }
            }
            guard self.id == token else { return }
            self.worker = nil
            self.completeIfReady()
        }
    }

    private func useRawFallback() {
        rawFallback = true
        worker?.cancel(); worker = nil
        corrected = []
    }

    private func completeIfReady() {
        guard stopped, let transcript = finalTranscript else { return }
        if correct == nil || rawFallback {
            finish(.completed(transcript, usedRawFallback: correct != nil && rawFallback))
        } else if corrected.count == segments.count {
            finish(.completed(corrected.joined(), usedRawFallback: false))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard id != nil else { return }
        id = nil
        worker?.cancel(); worker = nil
        recordingTimer?.cancel(); recordingTimer = nil
        tailTimer?.cancel(); tailTimer = nil
        correctionTimer?.cancel(); correctionTimer = nil
        segments = []; corrected = []; finalTranscript = nil
        onFinish(outcome)
    }

    private func timer(after delay: Duration, id token: UUID,
                       action: @escaping @MainActor (VoiceSession) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.id == token, !Task.isCancelled else { return }
            action(self)
        }
    }
}
