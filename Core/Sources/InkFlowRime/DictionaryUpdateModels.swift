import InkFlowDomain
import Foundation

package enum IFDictionaryStage: String, Codable, DiagnosticLabel {
    case check, download, prepare, verify, apply, rollback, recovery
    package var failureSummary: String {
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

/// Error.code is a String because worker/source failures cross a process boundary. Only these fixed
/// codes may enter the content-free local log; descriptions, source names and stderr never do.
package struct DictionaryDiagnosticCode: DiagnosticLabel {
    package let rawValue: String
    private static let allowed: Set<String> = [
        "underlying", "backend-unavailable", "bundled-unavailable", "engine-unavailable", "missing-check",
        "http-status", "non-http-response", "redirect-host", "request-host", "response-json", "response-size",
        "response-too-large", "commit-format", "checked-source", "tree-file", "tree-incomplete",
        "source-set", "source-checksum", "source-format", "source-location", "source-size",
        "activation-in-progress", "activation-mismatch", "invalid-state", "invalid-version", "invalid-receipt",
        "manifest-integrity", "manifest-legacy", "manifest-metadata", "manifest-source", "manifest-version",
        "missing-resources", "missing-runtime-resource", "nonregular-file", "observation-content",
        "prepared-checksum", "prepared-extra-files", "prepared-file-missing", "prepared-path", "prepared-version",
        "runtime-changed", "runtime-fingerprint", "symlink-path", "symlink-resource", "unsafe-candidate", "unsafe-path",
        "worker-arguments", "worker-exit", "worker-launch", "worker-timeout", "candidate-not-empty",
        "compiled-file-missing", "rebuild-integrity", "rime-compile", "smoke-probe", "legacy-changed",
        "calibration-empty", "correction-duplicate", "correction-format", "invalid-reading"
    ]
    package init(rawValue: String) { self.rawValue = Self.allowed.contains(rawValue) ? rawValue : "unknown" }
}

/// Diagnostic payloads are deliberately separate from the persistent state and manifest.
package struct IFDictionaryUpdateError: Error, LocalizedError, Codable, Sendable {
    package let stage: IFDictionaryStage
    package let code: String
    package let source: String?
    package let file: String?
    package let httpStatus: Int?
    package let exitStatus: Int32?
    package let detail: String
    package let stderr: String?
    package init(_ stage: IFDictionaryStage, _ code: String, source: String? = nil, file: String? = nil,
         httpStatus: Int? = nil, exitStatus: Int32? = nil, detail: String = "", stderr: String? = nil) {
        self.stage = stage; self.code = code; self.source = source; self.file = file
        self.httpStatus = httpStatus; self.exitStatus = exitStatus
        self.detail = String(detail.prefix(4096)); self.stderr = stderr.map { String($0.prefix(16384)) }
    }
    package var errorDescription: String? { stage.failureSummary }
    package var technicalDetails: String {
        ["stage=\(stage.rawValue)", "code=\(code)", source.map { "source=\($0)" },
         file.map { "file=\($0)" }, httpStatus.map { "HTTP=\($0)" }, exitStatus.map { "exit=\($0)" },
         detail.isEmpty ? nil : detail, stderr].compactMap { $0 }.joined(separator: "\n")
    }
    package static func wrapping(_ error: Error, stage: IFDictionaryStage, source: String? = nil) -> Self {
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

package typealias IFDictionaryDiagnosticLogger = @Sendable (IFDictionaryUpdateError) -> Void

package struct IFDictionaryProgress: Codable, Sendable {
    package let stage: IFDictionaryStage
    package let completed: Int
    package let total: Int
    package init(stage: IFDictionaryStage,
        completed: Int,
        total: Int) {
        self.stage = stage
        self.completed = completed
        self.total = total
    }

}

package struct IFDictionaryCheckedSource: Codable, Equatable, Sendable {
    package let id: String
    package let commit: String
    package let blobSHA: String
    package let byteCount: Int
    package init(id: String,
        commit: String,
        blobSHA: String,
        byteCount: Int) {
        self.id = id
        self.commit = commit
        self.blobSHA = blobSHA
        self.byteCount = byteCount
    }

}

package struct IFDictionaryCheck: Codable, Equatable, Sendable {
    package let sources: [IFDictionaryCheckedSource]
    package let hasUpdate: Bool
    package init(sources: [IFDictionaryCheckedSource],
        hasUpdate: Bool) {
        self.sources = sources
        self.hasUpdate = hasUpdate
    }

}
