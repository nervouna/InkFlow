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
        try await waitUntil { requests.count == 2 }
        precondition(requests == ["a", "b"] && results.isEmpty)
        session.stop(id: id)
        precondition(results.isEmpty)
        session.finalized(transcript: "ab", id: id)
        try await waitUntil { !results.isEmpty }
        precondition(results == [.completed("AB", usedRawFallback: false)])
        session.finalized(transcript: "ab", id: id)
        precondition(results.count == 1)
        // A later segment failure discards every earlier correction and includes the ASR tail.
        results = []
        let failed = VoiceSession(correct: { text in
            if text == "b" { throw VoiceCorrectionClient.Failure.incomplete }
            return text.uppercased()
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
        results = []
        limits.textUTF16 = 2
        let bounded = VoiceSession(limits: limits, onPreview: { _ in }, onRequestFinalize: { _ in },
                                   onFinish: { results.append($0) })
        let boundedID = bounded.start()
        bounded.receiveVolatile("abc", id: boundedID)
        precondition(results == [.failed(.boundExceeded)])

        // Empty corrections and adapter final-transcript mismatches always preserve full raw ASR.
        for replacement in ["", "correct"] {
            results = []
            let fallback = VoiceSession(correct: { _ in replacement }, onPreview: { _ in },
                onRequestFinalize: { _ in }, onFinish: { results.append($0) })
            let token = fallback.start()
            fallback.receiveFinal("raw", id: token)
            fallback.stop(id: token)
            fallback.finalized(transcript: replacement.isEmpty ? "raw" : "raw tail", id: token)
            try await Task.sleep(for: .milliseconds(10))
            precondition(results == [.completed(replacement.isEmpty ? "raw" : "raw tail", usedRawFallback: true)])
        }
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
