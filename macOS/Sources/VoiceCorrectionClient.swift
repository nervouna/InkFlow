import Foundation

/// Independent voice transport: no document context, Pinyin prompt, or prediction statistics.
struct VoiceCorrectionClient: Sendable {
    enum Failure: Error, Equatable { case invalidConfiguration, invalidResponse, empty, incomplete, network, http(Int) }
    private let session: URLSession
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: AIRejectRedirects(), delegateQueue: nil)
    }()

    init(session: URLSession? = nil) { self.session = session ?? Self.sharedSession }

    static func makeRequest(text: String, style: VoicePolishPrompt.Style,
                            configuration: AISuggestionConfiguration) throws -> URLRequest {
        guard let url = try? AIChatCompletionsClient.completionURL(configuration: configuration) else {
            throw Failure.invalidConfiguration
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 16_000 else { throw Failure.invalidResponse }
        let systemMessage = VoicePolishPrompt.systemMessage(style: style)
        var body: [String: Any] = ["model": configuration.model, "stream": false, "max_tokens": 2048, "temperature": 0,
            "messages": [["role": "system", "content": systemMessage], ["role": "user", "content": text]]]
        if AIChatCompletionsClient.thinkingDisabled(configuration) { body["thinking"] = ["type": "disabled"] }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func correct(text: String, style: VoicePolishPrompt.Style,
                 configuration: AISuggestionConfiguration) async throws -> String {
        try Task.checkCancellation()
        let request = try Self.makeRequest(text: text, style: style, configuration: configuration)
        var data = Data()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            // Cancelling the underlying task also stops oversized or non-success bodies.
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 128 * 1024 else { throw Failure.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            throw Failure.network
        }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> String {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard data.count <= 128 * 1024,
              let decoded = try? JSONDecoder().decode(Completion.self, from: data),
              decoded.choices.count == 1, let choice = decoded.choices.first else { throw Failure.invalidResponse }
        guard choice.finish_reason == "stop" else { throw Failure.incomplete }
        let text = (choice.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        guard text.utf16.count <= 16_000, !text.contains("```"),
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
              }) else { throw Failure.invalidResponse }
        return text
    }
}
