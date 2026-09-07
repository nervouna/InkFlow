import Foundation

@main
struct AILiveTests {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw AIServiceError.invalidConfiguration }
            let configuration = try AILiveConfiguration.loadConfiguration(path: CommandLine.arguments[1])
            guard URLComponents(string: configuration.baseURL)?.host?.lowercased() == "api.deepseek.com",
                  configuration.model.lowercased() == "deepseek-v4-flash" else { throw AIServiceError.invalidConfiguration }
            let fixtures: [(String, AISuggestionInput)] = [
                ("two-sided-context", .init(precedingText: "我正在开发一款", followingText: "，希望候选词更准确。", pinyin: "shurufa", selectedPrefix: "")),
                ("selected-prefix", .init(precedingText: "周末天气不错，", followingText: "，带上野餐垫。", pinyin: "qugongyuan", selectedPrefix: "我们")),
            ]
            let client = AIChatCompletionsClient()
            for (name, input) in fixtures {
                let start = ContinuousClock.now
                let suggestion = try await client.suggest(input: input, configuration: configuration)
                let elapsed = start.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                // Fixtures are synthetic. Defensively redact the secret even from unexpected provider output.
                let safe = suggestion.replacingOccurrences(of: configuration.apiKey, with: "[REDACTED]")
                let output = ["fixture": name, "seconds": String(format: "%.3f", seconds), "suggestion": safe]
                print(String(decoding: try JSONEncoder().encode(output), as: UTF8.self))
            }
            print("PASS live DeepSeek: production client, two synthetic contexts, nonempty complete suggestions")
        } catch {
            let message = (error as? AIServiceError)?.localizedDescription ?? "Live fixture configuration or execution failed."
            print("FAIL \(message)")
            exit(1)
        }
    }

}
