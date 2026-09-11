import Foundation
import SQLite3
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

package struct AIStatisticsTestDatabase {
    package let url: URL
    package init(url: URL) { self.url = url }
    package func rows(_ sql: String, writable: Bool = false) -> [[String: String]] {
        var db: OpaquePointer?
        precondition(sqlite3_open_v2(url.path, &db, writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sql)
        defer { sqlite3_finalize(statement) }
        var result: [[String: String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            precondition(code == SQLITE_ROW, sql)
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let text = sqlite3_column_text(statement, index) else { continue }
                row[String(cString: sqlite3_column_name(statement, index))] = String(cString: text)
            }
            result.append(row)
        }
    }
    package func scalar(_ sql: String) -> String? { rows(sql).first?.values.first }
}

package final class AIStatisticsTestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    package init() {}
    package var now: Date { lock.withLock { value } }
    package func advance(_ interval: TimeInterval) { lock.withLock { value += interval } }
    package var stamp: AIStatisticsStamp { .init(utc: now, monotonic: now.timeIntervalSince1970) }
}
