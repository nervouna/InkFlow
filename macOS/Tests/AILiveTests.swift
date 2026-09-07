import Foundation

@main
struct AILiveTests {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw FixtureError.invalidInput }
            let configuration = try loadConfiguration(path: CommandLine.arguments[1])
            guard URLComponents(string: configuration.baseURL)?.host?.lowercased() == "api.deepseek.com",
                  configuration.model.lowercased() == "deepseek-v4-flash" else { throw FixtureError.invalidInput }
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

    private enum FixtureError: Error { case invalidInput }

    private static func git(_ arguments: [String], in directory: URL) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    private static func loadConfiguration(path: String) throws -> AISuggestionConfiguration {
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let directory = file.deletingLastPathComponent()
        guard try git(["check-ignore", "--quiet", "--", file.path], in: directory).0 == 0,
              try git(["ls-files", "--error-unmatch", "--", file.path], in: directory).0 == 1 else { throw FixtureError.invalidInput }
        let text = try String(contentsOf: file, encoding: .utf8)
        let names: Set<String> = ["LLM_BASE_URL", "LLM_API_KEY", "LLM_MODEL"]
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard names.contains(key) else { continue }
            guard values[key] == nil else { throw FixtureError.invalidInput }
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                guard value.count >= 2, value.last == quote else { throw FixtureError.invalidInput }
                value = String(value.dropFirst().dropLast())
            }
            // This is a data parser. It never sources the file or expands shell syntax.
            values[key] = value
        }
        let configuration = AISuggestionConfiguration(baseURL: values["LLM_BASE_URL"] ?? "",
            apiKey: values["LLM_API_KEY"] ?? "", model: values["LLM_MODEL"] ?? "")
        guard configuration.isComplete else { throw FixtureError.invalidInput }
        return configuration
    }
}
