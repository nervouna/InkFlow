import AppKit
import Foundation

struct FeedbackMetadata: Equatable, Sendable {
    let version: String
    let build: String
    let operatingSystem: String

    static var live: Self {
        let bundle = Bundle.main
        return Self(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

struct FeedbackReportResult: Sendable {
    let url: URL
    let notice: String?
}

struct FeedbackLogCollector: Sendable {
    typealias Runner = @Sendable (URL, [String]) async throws -> String

    private let run: Runner

    init(run: @escaping Runner) {
        self.run = run
    }

    func collect() async throws -> String {
        try await run(
            URL(fileURLWithPath: "/usr/bin/log"),
            ["show", "--last", "10m", "--style", "compact", "--predicate",
             "subsystem == \"io.damao.inputmethod.inkflow\""]
        )
    }

    static let live = Self { executable, arguments in
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw FeedbackLogError.commandFailed(process.terminationStatus)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw FeedbackLogError.invalidUTF8
            }
            return text
        }.value
    }
}

enum FeedbackLogError: LocalizedError {
    case commandFailed(Int32)
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .commandFailed(let status): "日志命令失败（状态码 \(status)）。"
        case .invalidUTF8: "日志内容不是有效的 UTF-8 文本。"
        }
    }
}

struct FeedbackReporter: Sendable {
    typealias LogCollection = @Sendable () async throws -> String
    typealias URLOpener = @MainActor @Sendable (URL) -> Bool

    private static let issueTitle = "墨流问题反馈"
    private static let truncationMarker = "日志已截断，只保留最新内容。"
    private let metadata: FeedbackMetadata
    private let maximumURLLength: Int
    private let collectLogs: LogCollection
    private let openURL: URLOpener

    init(metadata: FeedbackMetadata, maximumURLLength: Int = 8_000,
         collectLogs: @escaping LogCollection, openURL: @escaping URLOpener) {
        self.metadata = metadata
        self.maximumURLLength = max(maximumURLLength, 1_000)
        self.collectLogs = collectLogs
        self.openURL = openURL
    }

    static let live = Self(metadata: .live, collectLogs: FeedbackLogCollector.live.collect) { url in
        NSWorkspace.shared.open(url)
    }

    func prepare(includeLogs: Bool) async -> FeedbackReportResult {
        guard includeLogs else {
            return FeedbackReportResult(url: issueURL(body: baseBody), notice: nil)
        }
        do {
            return report(including: try await collectLogs())
        } catch {
            let body = baseBody + "\n\n## 运行日志\n日志采集失败，未附加运行日志。"
            return FeedbackReportResult(
                url: issueURL(body: body),
                notice: "未能采集运行日志，已打开不含日志的反馈页面。"
            )
        }
    }

    @MainActor
    func open(_ report: FeedbackReportResult) -> Bool {
        openURL(report.url)
    }

    private var baseBody: String {
        """
        请描述遇到的问题、发生前的操作，以及能否稳定复现：


        ## 环境
        - 墨流版本：\(metadata.version) (\(metadata.build))
        - macOS：\(metadata.operatingSystem)
        """
    }

    private func report(including rawLogs: String) -> FeedbackReportResult {
        let logs = rawLogs.trimmingCharacters(in: .newlines)
        guard !logs.isEmpty else {
            let body = baseBody + "\n\n## 最近 10 分钟运行日志\n未找到最近的墨流运行日志。"
            return FeedbackReportResult(url: issueURL(body: body), notice: nil)
        }

        let completeBody = body(logs: logs, truncated: false)
        let completeURL = issueURL(body: completeBody)
        guard completeURL.absoluteString.utf8.count > maximumURLLength else {
            return FeedbackReportResult(url: completeURL, notice: nil)
        }

        let records = logs.split(separator: "\n", omittingEmptySubsequences: false)
        var lowerBound = 0
        var upperBound = records.count
        var newestRecords = ""
        while lowerBound <= upperBound {
            let count = (lowerBound + upperBound) / 2
            let candidate = records.suffix(count).joined(separator: "\n")
            if issueURL(body: body(logs: candidate, truncated: true)).absoluteString.utf8.count <= maximumURLLength {
                newestRecords = candidate
                lowerBound = count + 1
            } else {
                upperBound = count - 1
            }
        }

        if newestRecords.isEmpty, let newest = records.last {
            newestRecords = fittingSuffix(of: String(newest))
        }
        return FeedbackReportResult(
            url: issueURL(body: body(logs: newestRecords, truncated: true)),
            notice: "运行日志较长，已仅附上最新部分。"
        )
    }

    private func fittingSuffix(of record: String) -> String {
        let characters = Array(record)
        var lowerBound = 0
        var upperBound = characters.count
        var result = ""
        while lowerBound <= upperBound {
            let count = (lowerBound + upperBound) / 2
            let candidate = String(characters.suffix(count))
            if issueURL(body: body(logs: candidate, truncated: true)).absoluteString.utf8.count <= maximumURLLength {
                result = candidate
                lowerBound = count + 1
            } else {
                upperBound = count - 1
            }
        }
        return result
    }

    private func body(logs: String, truncated: Bool) -> String {
        var section = baseBody + "\n\n## 最近 10 分钟运行日志"
        if truncated { section += "\n\(Self.truncationMarker)" }
        section += "\n\n```text\n\(logs)\n```"
        return section
    }

    private func issueURL(body: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/nervouna/InkFlow/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: Self.issueTitle),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components.url else {
            fatalError("The static InkFlow GitHub issue URL must be valid")
        }
        return url
    }
}
