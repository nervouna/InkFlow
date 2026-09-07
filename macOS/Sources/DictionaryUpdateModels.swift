import Foundation

enum IFDictionaryStage: String, Codable, Sendable {
    case check, download, prepare, verify, apply, rollback, recovery
    var failureSummary: String {
        switch self {
        case .check: "检查词库更新失败"
        case .download: "下载词库失败"
        case .prepare: "准备词库失败"
        case .verify: "验证词库失败"
        case .apply: "应用词库失败"
        case .rollback: "恢复上一词库失败"
        case .recovery: "恢复词库状态失败"
        }
    }
}

/// Diagnostic payloads are deliberately separate from the persistent state and manifest.
struct IFDictionaryUpdateError: Error, LocalizedError, Codable, Sendable {
    let stage: IFDictionaryStage
    let code: String
    let source: String?
    let file: String?
    let httpStatus: Int?
    let exitStatus: Int32?
    let detail: String
    let stderr: String?
    init(_ stage: IFDictionaryStage, _ code: String, source: String? = nil, file: String? = nil,
         httpStatus: Int? = nil, exitStatus: Int32? = nil, detail: String = "", stderr: String? = nil) {
        self.stage = stage; self.code = code; self.source = source; self.file = file
        self.httpStatus = httpStatus; self.exitStatus = exitStatus
        self.detail = String(detail.prefix(4096)); self.stderr = stderr.map { String($0.prefix(16384)) }
    }
    var errorDescription: String? { stage.failureSummary }
    var technicalDetails: String {
        ["stage=\(stage.rawValue)", "code=\(code)", source.map { "source=\($0)" },
         file.map { "file=\($0)" }, httpStatus.map { "HTTP=\($0)" }, exitStatus.map { "exit=\($0)" },
         detail.isEmpty ? nil : detail, stderr].compactMap { $0 }.joined(separator: "\n")
    }
    static func wrapping(_ error: Error, stage: IFDictionaryStage, source: String? = nil) -> Self {
        if let known = error as? Self { return known }
        if let dictionary = error as? IFDictionaryError {
            return .init(stage, dictionary.code, source: dictionary.source ?? source,
                         detail: dictionary.errorDescription ?? dictionary.code)
        }
        let value = error as NSError
        // Do not include userInfo, which can contain URLs or arbitrary private payloads.
        return .init(stage, "underlying", source: source, detail: "\(value.domain) (\(value.code))")
    }
}

typealias IFDictionaryDiagnosticLogger = @Sendable (IFDictionaryUpdateError) -> Void

struct IFDictionaryProgress: Codable, Sendable {
    let stage: IFDictionaryStage
    let completed: Int
    let total: Int
}

struct IFDictionaryCheckedSource: Codable, Equatable, Sendable {
    let id: String
    let commit: String
    let blobSHA: String
    let byteCount: Int
}

struct IFDictionaryCheck: Codable, Equatable, Sendable {
    let sources: [IFDictionaryCheckedSource]
    let hasUpdate: Bool
}
