import Foundation

@main
struct AISuggestionTests {
    @MainActor static func main() async throws {
        try configuration()
        try requests()
        try await responses()
        print("PASS AI configuration and transport: isolated persistence, atomic credentials, URL/body/auth, responses and cancellation")
    }

    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    @MainActor static func configuration() throws {
        let suite = "inkflow.ai-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = MemoryAICredentialStore()
        let settings = IFSmartSettings(defaults: defaults, credentials: keys)
        expect(!settings.isEnabled && !settings.isAvailable, "AI must start off and incomplete")
        settings.isEnabled = true
        expect(!settings.isEnabled, "Incomplete settings cannot enable AI")
        try settings.save(baseURL: " not a URL ", apiKey: " fixture-key ", model: " fixture-model ")
        expect(settings.isAvailable, "Completeness requires only three nonempty values")
        expect(settings.configuration.baseURL == "not a URL", "Normalize surrounding whitespace")
        settings.isEnabled = true
        let reload = IFSmartSettings(defaults: defaults, credentials: keys)
        expect(reload.isEnabled && reload.configuration == settings.configuration, "Persist all fields, keeping key outside defaults")
        expect(!String(describing: defaults.persistentDomain(forName: suite)).contains("fixture-key"), "Key must never be written into defaults")
        keys.failWrites = true
        let previous = settings.configuration
        do {
            try settings.save(baseURL: "changed", apiKey: "changed-key", model: "changed")
            fatalError("Credential failure must reject the entire save")
        } catch {
            expect(settings.configuration == previous && settings.isEnabled, "Failed save must preserve current configuration")
            expect(IFSmartSettings(defaults: defaults, credentials: keys).configuration == previous, "Failed save must preserve persisted configuration")
            expect(!error.localizedDescription.contains("changed-key"), "Errors must not expose keys")
        }
        keys.failWrites = false
        for incomplete in [AISuggestionConfiguration(baseURL: "", apiKey: "a", model: "m"),
                           AISuggestionConfiguration(baseURL: "b", apiKey: "", model: "m"),
                           AISuggestionConfiguration(baseURL: "b", apiKey: "a", model: " ")] {
            try settings.save(baseURL: incomplete.baseURL, apiKey: incomplete.apiKey, model: incomplete.model)
            expect(!settings.isAvailable && !settings.isEnabled, "Every missing field disables AI")
        }
        keys.failReads = true
        let unreadable = IFSmartSettings(defaults: defaults, credentials: keys)
        expect(!unreadable.isAvailable && unreadable.credentialError != nil, "Unreadable key fails closed with safe UI error")
    }

    static let fixture = AISuggestionInput(precedingText: "朋友问：", followingText: "，很高兴见到你。", pinyin: "nihao", selectedPrefix: "")
    static let config = AISuggestionConfiguration(baseURL: "https://compatible.example/v1", apiKey: "fixture-key", model: "fixture-model")

    @MainActor static func requests() throws {
        for (base, expected) in [("https://compatible.example", "https://compatible.example/chat/completions"),
                                 ("https://compatible.example/v1/", "https://compatible.example/v1/chat/completions"),
                                 ("https://compatible.example/v1/chat/completions/", "https://compatible.example/v1/chat/completions")] {
            let request = try AIChatCompletionsClient.makeRequest(input: fixture, configuration: .init(baseURL: base, apiKey: "fixture-key", model: "fixture-model"))
            expect(request.url?.absoluteString == expected, "Endpoint normalization")
            expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "Standard method and bearer auth")
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            expect(json["model"] as? String == "fixture-model" && json["stream"] as? Bool == false && json["thinking"] == nil, "Compatible request uses standard fields")
            let messages = json["messages"] as! [[String: String]]
            let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
            expect(input["precedingText"] == fixture.precedingText && input["followingText"] == fixture.followingText && input["pinyin"] == "nihao" && input["selectedPrefix"] == "", "Both context sides, Pinyin and prefix must reach the model")
        }
        let deepseek = try AIChatCompletionsClient.makeRequest(input: fixture, configuration: .init(baseURL: "https://api.deepseek.com/v1", apiKey: "fixture-key", model: "deepseek-v4-flash"))
        let body = try JSONSerialization.jsonObject(with: deepseek.httpBody!) as! [String: Any]
        expect((body["thinking"] as? [String: String])?["type"] == "disabled", "Official DeepSeek V4 latency option")
        for invalid in ["bad URL", "file:///tmp/fixture", "https://user:secret@compatible.example", "https://compatible.example?key=secret", "https://compatible.example/#secret"] {
            do {
                _ = try AIChatCompletionsClient.makeRequest(input: fixture, configuration: .init(baseURL: invalid, apiKey: "fixture-key", model: "m"))
                fatalError("Invalid endpoint must fail at request time")
            } catch { expect(!error.localizedDescription.contains("secret"), "Errors must not include URL credentials") }
        }
    }

    @MainActor static func responses() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [AIStubURLProtocol.self]
        let client = AIChatCompletionsClient(session: URLSession(configuration: sessionConfig))
        AIStubURLProtocol.state.configure(status: 200, body: #"{"choices":[{"message":{"content":"  你好吗  "},"finish_reason":"stop"}]}"#)
        let suggestion = try await client.suggest(input: fixture, configuration: config)
        expect(suggestion == "你好吗", "Allow contextual expansion beyond Pinyin")
        for (status, body, expected) in [(401, "private server body fixture-key", AIServiceError.httpStatus(401)),
                                        (200, "malformed-private", .invalidResponse),
                                        (200, #"{"choices":[]}"#, .emptySuggestion),
                                        (200, #"{"choices":[{"message":{"content":"  "}}]}"#, .emptySuggestion),
                                        (200, #"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#, .incompleteSuggestion)] {
            AIStubURLProtocol.state.configure(status: status, body: body)
            do {
                _ = try await client.suggest(input: fixture, configuration: config)
                fatalError("Invalid response must fail")
            } catch {
                expect(error as? AIServiceError == expected, "Response error classification")
                expect(!error.localizedDescription.contains("private") && !error.localizedDescription.contains("fixture-key"), "Never expose server content")
            }
        }
        AIStubURLProtocol.state.configure(status: 200, body: #"{"choices":[{"message":{"content":"你好"}}]}"#)
        do {
            _ = try await client.suggest(input: .init(precedingText: "", followingText: "", pinyin: "nihao", selectedPrefix: "朋友"), configuration: config)
            fatalError("Selected prefix cannot be lost")
        } catch { expect(error as? AIServiceError == .invalidResponse, "Require selected prefix in complete replacement") }
        AIStubURLProtocol.state.configure(status: 200, body: "{}", delayed: true)
        let pending = Task { try await client.suggest(input: fixture, configuration: config) }
        for _ in 0..<100 where !AIStubURLProtocol.state.started { try await Task.sleep(for: .milliseconds(5)) }
        expect(AIStubURLProtocol.state.started, "Delayed request must start")
        pending.cancel()
        do { _ = try await pending.value; fatalError("Cancelled request cannot return a suggestion") }
        catch { expect(error is CancellationError, "Preserve cancellation as cancellation") }
        expect(AIStubURLProtocol.state.cancelled, "Cancellation must reach URLSession")
    }
}

final class AIStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var body = "{}"
    private var delayed = false
    private var didStart = false
    private var didCancel = false
    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func configure(status: Int, body: String, delayed: Bool = false) {
        lock.withLock { self.status = status; self.body = body; self.delayed = delayed; didStart = false; didCancel = false }
    }
    func start() -> (Int, String, Bool) { lock.withLock { didStart = true; return (status, body, delayed) } }
    func cancel() { lock.withLock { didCancel = true } }
}

final class AIStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = AIStubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body, delayed) = Self.state.start()
        guard !delayed else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.state.cancel() }
}
