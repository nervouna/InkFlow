import Foundation

final class AIDiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AIDiagnosticRecord] = []
    func append(_ record: AIDiagnosticRecord) { lock.withLock { storage.append(record) } }
    var records: [AIDiagnosticRecord] { lock.withLock { storage } }
    func contains(_ event: AIDiagnosticEvent, reason: AIDiagnosticReason? = nil) -> Bool {
        records.contains { $0.event == event && (reason == nil || $0.reason == reason) }
    }
    func excludes(_ sentinels: [String]) -> Bool {
        let messages = records.map(\.message).joined(separator: "\n")
        return sentinels.allSatisfy { !messages.contains($0) }
    }
}
