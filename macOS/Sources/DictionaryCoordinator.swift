import InkFlowRime
import Foundation
import OSLog

extension IFDictionaryServices {
    init(client: IFDictionarySourceClient, worker: IFDictionaryWorkerRunner) {
        self.init(check: { try await client.check(observed: $0) },
                  download: { try await client.download($0, progress: $1) },
                  prepare: { try await worker.prepare(candidate: $0, inputs: $1, existing: $2, progress: $3) },
                  rebuild: { try worker.rebuildBlocking(candidate: $0, dictionaryShared: $1) })
    }
}

extension IFDictionaryCoordinator {
    static let persistentLogger: IFDictionaryDiagnosticLogger = { failure in
        // Only source/protocol/worker diagnostics enter here, never document context or learning data.
        let log = Logger(subsystem: "io.damao.inputmethod.inkflow", category: "dictionary")
        let operation = UUID()
        LocalDiagnostics.shared.submit(.init(module: .dictionary, event: failure.stage, outcome: .failed,
            reason: DictionaryDiagnosticCode(rawValue: failure.code), correlation: operation,
            errorCode: failure.exitStatus.map(Int.init), httpStatus: failure.httpStatus))
        let event = operation.uuidString
        let parts = diagnosticChunks(failure.technicalDetails)
        for (index, part) in parts.enumerated() {
            log.error("event=\(event, privacy: .public) part=\(index + 1)/\(parts.count) \(part, privacy: .public)")
        }
    }

    /// Unified-log payloads truncate around 1 KiB on the target OS. Scalar-safe chunks retain bounded diagnostics.
    nonisolated static func diagnosticChunks(_ text: String) -> [String] {
        var parts: [String] = [], chunk = "", bytes = 0
        for scalar in text.unicodeScalars {
            let value = String(scalar), count = value.utf8.count
            if bytes + count > 700 { parts.append(chunk); chunk = ""; bytes = 0 }
            chunk += value; bytes += count
        }
        if !chunk.isEmpty { parts.append(chunk) }
        return parts
    }
}
