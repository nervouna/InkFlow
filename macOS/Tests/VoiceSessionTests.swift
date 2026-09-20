import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

@main
struct VoiceSessionTests {
@MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(condition(), "Timed out awaiting synthetic completion")
    }
    @MainActor static func main() async throws {
        var results: [VoiceSession.Outcome] = []
        var requests: [String] = []
        let session = VoiceSession(correct: { text in
            requests.append(text)
            try await Task.sleep(for: .milliseconds(5))
            return text.uppercased()
        }, onPreview: { _ in }, onRequestFinalize: { _ in }, onFinish: { results.append($0) })
        let id = session.start()
        session.receiveFinal("a", id: id)
        session.receiveFinal("b", id: id)
        try await Task.sleep(for: .milliseconds(20))
        precondition(requests.isEmpty && results.isEmpty,
                     "Final ASR fragments must remain local until the complete transcript is finalized")
        session.stop(id: id)
        precondition(results.isEmpty)
        session.finalized(transcript: "ab", id: id)
        try await waitUntil { !results.isEmpty }
        precondition(requests == ["ab"], "A voice session must correct its complete finalized transcript exactly once")
        precondition(results == [.completed("AB", usedRawFallback: false)])
        session.finalized(transcript: "ab", id: id)
        precondition(results.count == 1)
        // A whole-session correction failure preserves the complete finalized ASR transcript.
        results = []
        let failed = VoiceSession(correct: { _ in
            throw VoiceCorrectionClient.Failure.incomplete
        }, onPreview: { _ in }, onRequestFinalize: { _ in }, onFinish: { results.append($0) })
        let failureID = failed.start()
        failed.receiveFinal("a", id: failureID)
        failed.receiveFinal("b", id: failureID)
        await Task.yield()
        failed.stop(id: failureID)
        failed.receiveFinal("tail", id: failureID)
        failed.finalized(transcript: "abtail", id: failureID)
        try await Task.sleep(for: .milliseconds(20))
        precondition(results == [.completed("abtail", usedRawFallback: true)])

        // Cancellation wins even when the correction ignores task cancellation and returns later.
        results = []
        let cancelled = VoiceSession(correct: { _ in
            try? await Task.sleep(for: .milliseconds(20))
            return "late"
        }, onPreview: { _ in }, onRequestFinalize: { _ in }, onFinish: { results.append($0) })
        let old = cancelled.start()
        cancelled.receiveFinal("raw", id: old)
        await Task.yield()
        cancelled.stop(id: old)
        cancelled.finalized(transcript: "raw", id: old)
        cancelled.cancel(id: old)
        let fresh = cancelled.start()
        cancelled.finalized(transcript: "stale", id: old)
        cancelled.receiveFinal("stale", id: old)
        cancelled.stop(id: fresh)
        cancelled.finalized(transcript: "", id: fresh)
        try await Task.sleep(for: .milliseconds(30))
        precondition(results == [.cancelled, .completed("", usedRawFallback: false)])

        // Tail timeout discards partial recognition; correction deadline can only use finalized ASR.
        results = []
        var limits = VoiceSession.Limits()
        limits.tail = .milliseconds(5)
        let timeout = VoiceSession(limits: limits, onPreview: { _ in }, onRequestFinalize: { _ in },
                                   onFinish: { results.append($0) })
        let timeoutID = timeout.start()
        timeout.receiveFinal("partial", id: timeoutID)
        timeout.stop(id: timeoutID)
        try await Task.sleep(for: .milliseconds(20))
        precondition(results == [.failed(.finalizationTimedOut)])
        results = []
        limits.tail = .seconds(1); limits.correctionWait = .milliseconds(5)
        let deadline = VoiceSession(limits: limits, correct: { _ in
            try await Task.sleep(for: .seconds(2)); return "late"
        }, onPreview: { _ in }, onRequestFinalize: { _ in }, onFinish: { results.append($0) })
        let deadlineID = deadline.start()
        deadline.receiveFinal("raw", id: deadlineID)
        deadline.stop(id: deadlineID)
        try await Task.sleep(for: .milliseconds(20))
        precondition(results.isEmpty)
        deadline.receiveFinal("tail", id: deadlineID)
        deadline.finalized(transcript: "rawtail", id: deadlineID)
        precondition(results == [.completed("rawtail", usedRawFallback: true)])

        // A deadline that wins after whole-transcript correction starts completes once with full raw ASR.
        results = []
        limits.correctionWait = .milliseconds(10)
        var deadlineRequests: [String] = []
        var releaseLateCorrection: CheckedContinuation<Void, Never>?
        var lateCorrectionReturned = false
        let lateDeadline = VoiceSession(limits: limits, correct: { text in
            deadlineRequests.append(text)
            await withCheckedContinuation { releaseLateCorrection = $0 }
            lateCorrectionReturned = true
            return "late corrected"
        }, onPreview: { _ in }, onRequestFinalize: { _ in }, onFinish: { results.append($0) })
        let lateDeadlineID = lateDeadline.start()
        lateDeadline.receiveFinal("raw", id: lateDeadlineID)
        lateDeadline.receiveFinal(" tail", id: lateDeadlineID)
        lateDeadline.stop(id: lateDeadlineID)
        precondition(deadlineRequests.isEmpty)
        lateDeadline.finalized(transcript: "raw tail", id: lateDeadlineID)
        try await waitUntil { deadlineRequests == ["raw tail"] }
        try await waitUntil { !results.isEmpty }
        precondition(results == [.completed("raw tail", usedRawFallback: true)])
        releaseLateCorrection?.resume()
        releaseLateCorrection = nil
        try await waitUntil { lateCorrectionReturned }
        await Task.yield()
        precondition(results == [.completed("raw tail", usedRawFallback: true)],
                     "A late correction that ignored cancellation must not complete the session again")

        results = []
        limits.textUTF16 = 2
        let bounded = VoiceSession(limits: limits, onPreview: { _ in }, onRequestFinalize: { _ in },
                                   onFinish: { results.append($0) })
        let boundedID = bounded.start()
        bounded.receiveVolatile("abc", id: boundedID)
        precondition(results == [.failed(.boundExceeded)])

        // Empty corrections preserve the complete finalized raw transcript.
        results = []
        let fallback = VoiceSession(correct: { _ in "" }, onPreview: { _ in },
            onRequestFinalize: { _ in }, onFinish: { results.append($0) })
        let fallbackID = fallback.start()
        fallback.receiveFinal("raw", id: fallbackID)
        fallback.stop(id: fallbackID)
        fallback.finalized(transcript: "raw tail", id: fallbackID)
        try await Task.sleep(for: .milliseconds(10))
        precondition(results == [.completed("raw tail", usedRawFallback: true)])

        // The finalized transcript is canonical even if adapter fragments differed.
        results = []
        var canonicalRequests: [String] = []
        let canonical = VoiceSession(correct: { text in canonicalRequests.append(text); return "correct" },
            onPreview: { _ in }, onRequestFinalize: { _ in }, onFinish: { results.append($0) })
        let canonicalID = canonical.start()
        canonical.receiveFinal("raw", id: canonicalID)
        canonical.stop(id: canonicalID)
        canonical.finalized(transcript: "raw tail", id: canonicalID)
        try await Task.sleep(for: .milliseconds(10))
        precondition(canonicalRequests == ["raw tail"])
        precondition(results == [.completed("correct", usedRawFallback: false)])
        let configuration = AISuggestionConfiguration(baseURL: "https://api.deepseek.com/v1", apiKey: "fixture", model: "deepseek-v4-flash")
        let request = try VoiceCorrectionClient.makeRequest(text: "测试", configuration: configuration)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(request.url!.path == "/v1/chat/completions")
        precondition((body["thinking"] as? [String: String]) == ["type": "disabled"])
        precondition(body["stream"] as? Bool == false)
        for finish in ["length", "content_filter", "null"] {
            let data = Data("{\"choices\":[{\"finish_reason\":\"\(finish)\",\"message\":{\"content\":\"partial\"}}]}".utf8)
            do { _ = try VoiceCorrectionClient.decode(data); preconditionFailure("Accepted incomplete response") }
            catch { precondition(error as? VoiceCorrectionClient.Failure == .incomplete) }
        }
        let empty = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":" "}}]}"#.utf8)
        do { _ = try VoiceCorrectionClient.decode(empty); preconditionFailure("Accepted empty response") }
        catch { precondition(error as? VoiceCorrectionClient.Failure == .empty) }
        let valid = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"测试。"}}]}"#.utf8)
        let decoded = try VoiceCorrectionClient.decode(valid)
        precondition(decoded == "测试。")
        for (baseURL, endpoint) in [("http://localhost:11434/v1/", "http://localhost:11434/v1/chat/completions"),
                                    ("https://example.org/custom/api", "https://example.org/custom/api/chat/completions"),
                                    ("https://example.org/v1/chat/completions/", "https://example.org/v1/chat/completions")] {
            let config = AISuggestionConfiguration(baseURL: baseURL, apiKey: "ollama", model: "local-model")
            let generic = try VoiceCorrectionClient.makeRequest(text: "测试", configuration: config)
            let genericBody = try JSONSerialization.jsonObject(with: generic.httpBody!) as! [String: Any]
            precondition(config.isComplete && generic.url?.absoluteString == endpoint)
            precondition(generic.value(forHTTPHeaderField: "Authorization") == "Bearer ollama")
            precondition(genericBody["thinking"] == nil, "Generic services do not receive DeepSeek-only fields")
        }
        let otherModel = try VoiceCorrectionClient.makeRequest(text: "测试",
            configuration: .init(baseURL: "https://api.deepseek.com", apiKey: "fixture", model: "other-model"))
        let otherModelBody = try JSONSerialization.jsonObject(with: otherModel.httpBody!) as! [String: Any]
        precondition(otherModelBody["thinking"] == nil)
        for baseURL in ["file:///tmp/model", "https://user:password@example.org", "https://example.org?key=fixture", "https://example.org/#fragment"] {
            do {
                _ = try VoiceCorrectionClient.makeRequest(text: "test", configuration: .init(baseURL: baseURL, apiKey: "fixture", model: "model"))
                preconditionFailure("Accepted unsupported endpoint")
            } catch { precondition(error as? VoiceCorrectionClient.Failure == .invalidConfiguration) }
        }
        results = []
        let smallRanges = VoiceSession(onPreview: { _ in }, onRequestFinalize: { _ in }, onFinish: { results.append($0) })
        let manyID = smallRanges.start()
        for _ in 0..<512 { smallRanges.receiveFinal("字", id: manyID) }
        smallRanges.stop(id: manyID)
        smallRanges.finalized(transcript: String(repeating: "字", count: 512), id: manyID)
        precondition(results == [.completed(String(repeating: "字", count: 512), usedRawFallback: false)])
        results = []
        let tooManyID = smallRanges.start()
        for _ in 0..<513 { smallRanges.receiveFinal("字", id: tooManyID) }
        precondition(results == [.failed(.boundExceeded)])
        print("Voice session and transport tests passed")


    }
}
