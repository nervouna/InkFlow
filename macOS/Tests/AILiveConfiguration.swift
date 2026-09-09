import Foundation

enum AILiveConfiguration {
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

    static func loadConfiguration(path: String) throws -> AISuggestionConfiguration {
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
