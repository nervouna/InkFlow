import Foundation
import SQLite3

/// Manual export runs on a separate utility task, never on the recorder or key-event queue.
enum QualityExport {
    static let columns: [String: String] = [
        "recording_runs": "id started_at ended_at status engine_version build_metadata_json metric_rule_version stats_json error_code",
        "config_revisions": "id fingerprint created_at applied_config_json build_metadata_json engine_version metric_rule_version ranking_fingerprint settings_fingerprint measurement_fingerprint build_identity",
        "compositions": "id run_id started_at ended_at app_bundle_id client_id outcome page_history_truncated dropped_page_count outcome_reason operations_json",
        "commits": "id composition_id issued_at text kind insertion_issued client_id",
        "candidate_decisions": "id composition_id config_revision_id commit_id occurred_at sequence trigger outcome selected_display_index selected_text text_kind snapshot_json first_page_json visited_pages_json page_history_truncated dropped_page_count operations_json regular_ranked_selection matches_custom_phrase unknown_rank_reason path_reason",
        "effectiveness_events": "id run_id occurred_at source event reason count milliseconds"
    ]

    private struct ExportError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func write(database: URL, destination: URL) throws -> String {
        guard database.standardizedFileURL != destination.standardizedFileURL,
              destination.lastPathComponent != "quality-source-id" else {
            throw ExportError("请选择新的 JSON 文件，不能覆盖质量数据库或来源标识。")
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw ExportError("无法读取本机质量数据库。请先使用墨流记录输入。")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        func query(_ sql: String) throws -> [[String: Any]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ExportError("质量数据库格式不兼容或读取失败。")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [[String: Any]] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return rows }
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
                        row[key] = String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
                    default: throw ExportError("质量记录包含不支持的数据。")
                    }
                }
                rows.append(row)
            }
        }
        _ = try query("BEGIN")
        guard try query("PRAGMA user_version").first?["user_version"] as? Int64 == 3,
              try query("PRAGMA application_id").first?["application_id"] as? Int64 == 0x49465131 else {
            throw ExportError("质量数据库格式不兼容，请升级墨流后重试。")
        }
        let names = try query("SELECT name FROM sqlite_master WHERE type='table' AND substr(name,1,7)!='sqlite_'")
        guard Set(names.compactMap { $0["name"] as? String }) == Set(columns.keys),
              try query("PRAGMA foreign_key_check").isEmpty else {
            throw ExportError("质量数据库结构不兼容或记录关联损坏。")
        }
        var tables: [String: [[String: Any]]] = [:]
        for (table, names) in columns {
            let actualColumns = try query("PRAGMA table_info(\(table))")
            guard Set(actualColumns.compactMap { $0["name"] as? String }) == Set(names.split(separator: " ").map(String.init)) else {
                throw ExportError("质量数据库字段不兼容。")
            }
            var records = try query("SELECT \(names.split(separator: " ").joined(separator: ",")) FROM \(table) ORDER BY id")
            for index in records.indices {
                if table == "config_revisions" { records[index]["applied_config_json"] = "{}" }
                if table == "candidate_decisions" {
                    for field in ["snapshot_json", "first_page_json", "visited_pages_json"] {
                        guard let text = records[index][field] as? String else { continue }
                        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
                        let clean: Any
                        if let pages = object as? [[String: Any]], field == "visited_pages_json" {
                            clean = pages.map { page in var page = page; page.removeValue(forKey: "configuration"); return page }
                        } else if var page = object as? [String: Any], field != "visited_pages_json" {
                            page.removeValue(forKey: "configuration"); clean = page
                        } else { throw ExportError("候选记录损坏，导出未完成。") }
                        records[index][field] = String(decoding: try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]), as: UTF8.self)
                    }
                }
            }
            tables[table] = records
        }
        _ = try query("ROLLBACK") // Release the read lock before encoding or writing the file.
        let sourceFile = database.deletingLastPathComponent().appendingPathComponent("quality-source-id")
        if !FileManager.default.fileExists(atPath: sourceFile.path) {
            do { try Data(UUID().uuidString.lowercased().utf8).write(to: sourceFile, options: .withoutOverwriting) }
            catch where FileManager.default.fileExists(atPath: sourceFile.path) { /* Another export created it. */ }
        }
        let source = try String(contentsOf: sourceFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: source) != nil else { throw ExportError("质量数据来源标识损坏，原文件已保留。") }
        let times = (tables["compositions"] ?? []).compactMap { $0["started_at"] as? String }
            + (tables["effectiveness_events"] ?? []).compactMap { $0["occurred_at"] as? String }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let document: [String: Any] = ["format": "inkflow-quality", "format_version": 1, "schema_version": 3,
            "source_id": source.lowercased(), "exported_at": formatter.string(from: Date()),
            "range": ["first": times.min().map { $0 as Any } ?? NSNull(), "last": times.max().map { $0 as Any } ?? NSNull()],
            "tables": tables]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        guard data.count <= 256 * 1024 * 1024 else {
            throw ExportError("导出文件超过 256 MiB，未保存文件。")
        }
        try data.write(to: destination, options: .atomic)
        let count = tables["compositions"]?.count ?? 0
        let events = tables["effectiveness_events"]?.count ?? 0
        let range = times.min().map { "\($0) 至 \(times.max()!)" } ?? "无已保留记录"
        return "已保存到 \(destination.path)\n\(count) 段输入、\(events) 条学习效果事件。记录时间（UTC）：\(range)。"
    }
}
