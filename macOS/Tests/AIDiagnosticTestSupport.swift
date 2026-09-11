import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

package final class AIDiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AIDiagnosticRecord] = []
    package init() {}
    package func append(_ record: AIDiagnosticRecord) { lock.withLock { storage.append(record) } }
    package var records: [AIDiagnosticRecord] { lock.withLock { storage } }
    package func contains(_ event: AIDiagnosticEvent, reason: AIDiagnosticReason? = nil) -> Bool {
        records.contains { $0.event == event && (reason == nil || $0.reason == reason) }
    }
    package func excludes(_ sentinels: [String]) -> Bool {
        let messages = records.map(\.message).joined(separator: "\n")
        return sentinels.allSatisfy { !messages.contains($0) }
    }
}
