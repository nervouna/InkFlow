import Foundation
import SQLite3
import zlib

/// Manual export runs on a separate utility task, never on the recorder or key-event queue.
enum QualityExport {
    static let columns: [String: String] = [
        "recording_runs": "id started_at ended_at status engine_version build_metadata_json metric_rule_version stats_json error_code",
        "config_revisions": "id fingerprint created_at applied_config_json build_metadata_json engine_version metric_rule_version ranking_fingerprint settings_fingerprint measurement_fingerprint build_identity",
        "compositions": "id run_id started_at ended_at app_bundle_id client_id outcome page_history_truncated dropped_page_count outcome_reason operations_json",
        "commits": "id composition_id issued_at text kind insertion_issued client_id character_count",
        "candidate_decisions": "id composition_id config_revision_id commit_id occurred_at sequence trigger outcome "
            + "selected_display_index selected_text text_kind snapshot_json first_page_json visited_pages_json "
            + "page_history_truncated dropped_page_count operations_json regular_ranked_selection "
            + "matches_custom_phrase unknown_rank_reason path_reason selected_character_count",
        "effectiveness_events": "id run_id occurred_at source event reason count milliseconds"
    ]

    private struct ExportError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// `textFree` writes every record the way the recorder stores it with text recording off: positions, ranks,
    /// counts, timings, evidence rows and keyed hashes stay; raw input, candidate, selected, committed and context
    /// text and the input before a deletion go, and so do the visited pages, which only `inspect` reads. The
    /// automatic export always uses it.
    /// `since` keeps the compositions that started at or after it, with their commits and decisions, and the
    /// learning events from then on; runs and configuration revisions are always complete.
    /// Rows go from SQLite to the file one at a time, so memory does not grow with the store. `gzip` compresses
    /// the same document. The limit is on the document's own size either way.
    static func write(database: URL, destination: URL, textFree: Bool = false, since: Date? = nil,
                      gzip: Bool = false) throws -> String {
        guard database.standardizedFileURL != destination.standardizedFileURL,
              !["quality-source-id", "quality-pair-key"].contains(destination.lastPathComponent) else {
            throw ExportError("请选择新的 JSON 文件，不能覆盖质量数据库、来源标识或配对密钥。")
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw ExportError("无法读取本机质量数据库。请先使用墨流记录输入。")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        func each(_ sql: String, _ body: ([String: Any]) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ExportError("质量数据库格式不兼容或读取失败。")
            }
            defer { sqlite3_finalize(statement) }
            // One pool per row: the JSON objects of a row are released before the next one is read.
            while try autoreleasepool(invoking: { () throws -> Bool in
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return false }
                guard code == SQLITE_ROW else { throw ExportError("质量数据库忙碌或读取失败，请稍后重试。") }
                var row: [String: Any] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let key = String(cString: sqlite3_column_name(statement, index))
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_NULL: row[key] = NSNull()
                    case SQLITE_INTEGER: row[key] = sqlite3_column_int64(statement, index)
                    case SQLITE_FLOAT: row[key] = sqlite3_column_double(statement, index)
                    case SQLITE_TEXT:
                        guard let text = sqlite3_column_text(statement, index) else { throw ExportError("质量文本读取失败。") }
                        let bytes = UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, index)))
                        row[key] = String(decoding: bytes, as: UTF8.self)
                    default: throw ExportError("质量记录包含不支持的数据。")
                    }
                }
                try body(row)
                return true
            }) {}
        }
        func query(_ sql: String) throws -> [[String: Any]] {
            var rows: [[String: Any]] = []
            try each(sql) { rows.append($0) }
            return rows
        }
        _ = try query("BEGIN")
        guard try query("PRAGMA user_version").first?["user_version"] as? Int64 == 4,
              try query("PRAGMA application_id").first?["application_id"] as? Int64 == 0x49465131 else {
            throw ExportError("质量数据库格式不兼容，请升级墨流后重试。")
        }
        let names = try query("SELECT name FROM sqlite_master WHERE type='table' AND substr(name,1,7)!='sqlite_'")
        guard Set(names.compactMap { $0["name"] as? String }) == Set(columns.keys),
              try query("PRAGMA foreign_key_check").isEmpty else {
            throw ExportError("质量数据库结构不兼容或记录关联损坏。")
        }
        for (table, names) in columns {
            let actualColumns = try query("PRAGMA table_info(\(table))")
            guard Set(actualColumns.compactMap { $0["name"] as? String }) == Set(names.split(separator: " ").map(String.init)) else {
                throw ExportError("质量数据库字段不兼容。")
            }
        }
        let source = try sourceID(beside: database)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Stored times are UTC ISO-8601 with milliseconds, so they compare as text.
        let cutoff = since.map { "'" + formatter.string(from: $0) + "'" }
        let recent = cutoff.map { "(SELECT id FROM compositions WHERE started_at >= \($0))" }
        // The document is written beside its destination and moved into place when complete.
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + ".partial")
        let sink = try Sink(url: partial, gzip: gzip, limit: 256 * 1024 * 1024)
        var counts: [String: Int] = [:]
        var first: String?, last: String?
        do {
            try sink.write("{\"tables\":{")
            for (position, table) in columns.keys.sorted().enumerated() {
                var filter = ""
                if let cutoff, let recent {
                    switch table {
                    case "compositions": filter = " WHERE started_at >= \(cutoff)"
                    case "commits", "candidate_decisions": filter = " WHERE composition_id IN \(recent)"
                    case "effectiveness_events": filter = " WHERE occurred_at >= \(cutoff)"
                    default: break
                    }
                }
                try sink.write((position == 0 ? "" : ",") + "\"\(table)\":[")
                let fields = columns[table]!.split(separator: " ").joined(separator: ",")
                var written = 0
                try each("SELECT \(fields) FROM \(table)\(filter) ORDER BY id") { record in
                    var record = record
                    if table == "config_revisions" { record["applied_config_json"] = "{}" }
                    if textFree {
                        if table == "commits" { record["text"] = "" }
                        if table == "candidate_decisions" {
                            record["selected_text"] = NSNull()
                            record["visited_pages_json"] = "[]"
                        }
                        if table == "compositions" || table == "candidate_decisions" {
                            record["operations_json"] = try withoutDeletedInput(record["operations_json"])
                        }
                    }
                    if table == "candidate_decisions" {
                        for field in ["snapshot_json", "first_page_json", "visited_pages_json"] {
                            guard let text = record[field] as? String else { continue }
                            let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
                            let clean: Any
                            if let pages = object as? [[String: Any]], field == "visited_pages_json" {
                                clean = pages.map { exported($0, textFree: textFree) }
                            } else if let page = object as? [String: Any], field != "visited_pages_json" {
                                clean = exported(page, textFree: textFree)
                            } else { throw ExportError("候选记录损坏，导出未完成。") }
                            let data = try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
                            record[field] = String(decoding: data, as: UTF8.self)
                        }
                    }
                    let time = table == "compositions" ? record["started_at"] as? String
                        : table == "effectiveness_events" ? record["occurred_at"] as? String : nil
                    if let time {
                        first = min(first ?? time, time)
                        last = max(last ?? time, time)
                    }
                    if written > 0 { try sink.write(",") }
                    try sink.write(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                    written += 1
                }
                counts[table] = written
                try sink.write("]")
            }
            _ = try query("ROLLBACK")
            let head: [String: Any] = ["format": "inkflow-quality", "format_version": 1, "schema_version": 4,
                "source_id": source, "exported_at": formatter.string(from: Date()),
                "range": ["first": first.map { $0 as Any } ?? NSNull(), "last": last.map { $0 as Any } ?? NSNull()]]
            let fields = try JSONSerialization.data(withJSONObject: head, options: [.sortedKeys])
            // `head` is an object: its fields follow the tables inside the same braces.
            try sink.write("},")
            try sink.write(fields.dropFirst())
            try sink.close()
        } catch {
            sink.abandon()
            throw error
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        let count = counts["compositions"] ?? 0
        let events = counts["effectiveness_events"] ?? 0
        let range = first.map { "\($0) 至 \(last!)" } ?? "无已保留记录"
        return "已保存到 \(destination.path)\n\(count) 段输入、\(events) 条学习效果事件。记录时间（UTC）：\(range)。"
    }

    /// The export file being written: plain or gzip, counted in document bytes.
    private final class Sink {
        private let url: URL
        private let limit: Int
        private var plain: FileHandle?
        private var compressed: gzFile?
        private var bytes = 0

        init(url: URL, gzip: Bool, limit: Int) throws {
            self.url = url
            self.limit = limit
            try? FileManager.default.removeItem(at: url)
            if gzip {
                compressed = gzopen(url.path, "wb6")
                guard compressed != nil else { throw ExportError("无法写入导出文件，请检查文件夹是否存在并可写。") }
            } else {
                guard FileManager.default.createFile(atPath: url.path, contents: nil),
                      let handle = FileHandle(forWritingAtPath: url.path) else {
                    throw ExportError("无法写入导出文件，请检查文件夹是否存在并可写。")
                }
                plain = handle
            }
        }

        func write(_ text: String) throws { try write(Data(text.utf8)) }

        func write(_ data: Data) throws {
            bytes += data.count
            guard bytes <= limit else { throw ExportError("导出文件超过 256 MiB，未保存文件。") }
            if let compressed {
                let written = data.withUnsafeBytes { gzwrite(compressed, $0.baseAddress, UInt32($0.count)) }
                guard written == Int32(data.count) else { throw ExportError("写入导出文件失败。") }
            } else {
                try plain?.write(contentsOf: data)
            }
        }

        func close() throws {
            if let compressed {
                self.compressed = nil
                guard gzclose(compressed) == Z_OK else { throw ExportError("写入导出文件失败。") }
            }
            try plain?.close()
            plain = nil
        }

        func abandon() {
            if let compressed { gzclose(compressed) }
            compressed = nil
            try? plain?.close()
            plain = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The device's export identity, created beside the database on first use.
    static func sourceID(beside database: URL) throws -> String {
        let sourceFile = database.deletingLastPathComponent().appendingPathComponent("quality-source-id")
        if !FileManager.default.fileExists(atPath: sourceFile.path) {
            do { try Data(UUID().uuidString.lowercased().utf8).write(to: sourceFile, options: .withoutOverwriting) }
            catch where FileManager.default.fileExists(atPath: sourceFile.path) { /* Another export created it. */ }
        }
        let source = try String(contentsOf: sourceFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: source) != nil else { throw ExportError("质量数据来源标识损坏，原文件已保留。") }
        return source.lowercased()
    }

    /// A stored page as the export carries it: never its configuration, and without its strings when text-free
    /// (the fields `QualityPageSnapshot.redactingText` clears).
    private static func exported(_ page: [String: Any], textFree: Bool) -> [String: Any] {
        var page = page
        page.removeValue(forKey: "configuration")
        guard textFree else { return page }
        for key in ["rawInput", "selectedPrefix", "precedingContext"] where page[key] != nil { page[key] = "" }
        if let candidates = page["candidates"] as? [[String: Any]] {
            page["candidates"] = candidates.map { candidate in
                var candidate = candidate
                candidate["text"] = ""
                candidate.removeValue(forKey: "comment")
                return candidate
            }
        }
        page["textCaptured"] = false
        return page
    }

    private static func withoutDeletedInput(_ value: Any?) throws -> Any {
        guard let text = value as? String else { return value ?? NSNull() }
        guard var operations = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ExportError("操作记录损坏，导出未完成。")
        }
        guard operations.removeValue(forKey: "inputBeforeDeletion") != nil else { return text }
        let data = try JSONSerialization.data(withJSONObject: operations, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// The weekly export to a folder the user chose. It writes a local file and nothing else: the user's own sync moves
/// it. Always text-free. Each export is one dated file per device that holds the records since the last export plus
/// a day of overlap, and the device's own files older than `kept` are removed, so the folder covers the retention
/// window without one file outgrowing the export limit.
enum QualityAutoExport {
    static let interval: TimeInterval = 7 * 24 * 60 * 60
    private static let day: TimeInterval = 24 * 60 * 60
    /// The first export, and the most any export reaches back.
    static let firstWindow = 8 * day
    static let longestWindow = 14 * day
    static let kept = 35 * day
    static let suffix = ".json.gz"

    static func isDue(enabled: Bool, folder: String?, lastSuccess: Date?, now: Date) -> Bool {
        guard enabled, let folder, !folder.isEmpty else { return false }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= interval
    }

    static func cutoff(lastSuccess: Date?, now: Date) -> Date {
        guard let lastSuccess, lastSuccess <= now else { return now - firstWindow }
        return now - min(now.timeIntervalSince(lastSuccess) + day, longestWindow)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func run(database: URL, folder: URL, lastSuccess: Date?, now: Date) throws -> String {
        let prefix = "InkFlow-quality-\(try QualityExport.sourceID(beside: database))-"
        let destination = folder.appendingPathComponent(prefix + stamp(now) + suffix)
        let result = try QualityExport.write(database: database, destination: destination, textFree: true,
                                             since: cutoff(lastSuccess: lastSuccess, now: now), gzip: true)
        // Only this device's dated files, and only after the new one is in place.
        let oldest = stamp(now - kept)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let date = name.dropFirst(prefix.count).dropLast(suffix.count)
            guard date.count == 8, date.allSatisfy(\.isNumber), date < oldest else { continue }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        return result
    }
}
