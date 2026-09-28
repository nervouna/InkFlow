import Foundation
import InkFlowDomain
import InkFlowRime
import InkFlowRimeNative
import Darwin

struct PersonalDataError: LocalizedError, Sendable {
    let code: String
    var errorDescription: String? { "个人数据操作未完成（\(code)）。原有数据的恢复状态请重新启动墨流后检查。" }
    init(_ code: String) { self.code = code }
    static func report(_ error: any Error) -> String {
        let code = (error as? Self)?.code ?? (error as? IFDictionaryUpdateError)?.code ?? "filesystem"
        let reason: StaticString
        let message: String
        switch code {
        case "personal-data-busy", "personal-data-composition", "personal-data-undo-grace", "voice-busy":
            reason = "busy"; message = "请先完成所有应用中正在输入或听写的内容，等待词库准备结束并稍等片刻后重试。"
        case "incompatible", "snapshot", "unknown-fields", "settings", "shortcuts", "shortcut-binding", "shortcut-conflict", "worker-native-map", "worker-snapshot", "worker-size", "file-size-or-type":
            reason = "invalidBackup"; message = "此备份不兼容、数据无效或超过大小限制，未恢复。请选择有效的墨流备份。"
        case "recovery-required", "rollback-persistence":
            reason = "recoveryRequired"; message = "恢复尚未完成，已暂停输入和设置修改。请退出并重新启动墨流以恢复原有数据。"
        default:
            reason = "operationFailed"; message = "操作未完成。请检查文件访问权限和可用磁盘空间后重试。"
        }
        let stages = ["worker-request": 2, "worker-path": 3, "worker-snapshot": 4, "worker-native-map": 5,
                      "worker-size": 6, "worker-filesystem": 7, "preferences-persistence": 8, "recovery-required": 9]
        LocalDiagnostics.shared.submit(.init(module: .dictionary, event: "personalData", outcome: .failed, reason: reason, errorCode: stages[code]))
        return message
    }
}

/// UserDefaults is thread-safe; this wrapper only transfers its existing owner to a utility task.
struct PersonalDefaults: @unchecked Sendable {
    let defaults: UserDefaults
    func rollbackPreferences() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for key in PersonalBackupSettings.keys {
            if let value = defaults.object(forKey: key) { result[key] = try PersonalBackupSettings.plist(value) }
        }
        return result
    }
    func synchronize() -> Bool { defaults.synchronize() }
}

struct PersonalBackupSettings: Codable, Sendable {
    var integers: [String: Int]
    var shortcuts: [String: ShortcutBinding]
    var phrases: [CustomPhrase]
    var voiceRules: [VoicePolishRule]
    static let integerKeys = Set(["candidateCount", "fontSize", "vertical", "thunderMode"] + InputOption.allCases.map { "input.\($0.rawValue)" })
    static let keys = integerKeys.union(ShortcutAction.allCases.map { "shortcut.\($0.rawValue)" }).union(["customPhrases", "voicePolishRules"])
    func validate() throws {
        guard Set(integers.keys) == Self.integerKeys,
              (3...9).contains(integers["candidateCount"]!), [14,16,18,24,36].contains(integers["fontSize"]!),
              integers.allSatisfy({ ["candidateCount", "fontSize"].contains($0.key) || [0,1].contains($0.value) }),
              integers["input.fuzzyZ"] == integers["input.fuzzyC"], integers["input.fuzzyC"] == integers["input.fuzzyS"],
              integers["input.bracketPaging"] != integers["input.minusEqualPaging"] else { throw PersonalDataError("settings") }
        try KeyboardShortcuts.validateBackup(shortcuts)
        try CustomPhrase.validate(phrases)
        try VoicePolishRule.validate(voiceRules)
    }
    func encodedPreferences() throws -> [String: Data] {
        try validate()
        var result = try integers.mapValues { try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
        for (key, binding) in shortcuts { result["shortcut.\(key)"] = try Self.plist(JSONEncoder().encode(binding)) }
        result["customPhrases"] = try Self.plist(JSONEncoder().encode(phrases))
        result["voicePolishRules"] = try Self.plist(JSONEncoder().encode(voiceRules))
        return result
    }
    static func plist(_ value: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) }
}

struct PersonalBackupDocument: Codable, Sendable {
    var format: Int = 1
    var rime: String
    var settings: PersonalBackupSettings
    // nil is explicit absence; an empty native dictionary remains a non-nil snapshot.
    var dictionaries: [String: String?]
    static let names = ["pinyin_simp", "inkflow_shared_english", "inkflow_voice_alias"]
    static let maximumBytes = 128 * 1024 * 1024
    func preview() -> String {
        let labels = ["中文", "英文", "语音词条"]
        return zip(Self.names, labels).map { name, label in
            guard let snapshot = dictionaries[name] ?? nil else { return "\(label)：备份中不存在，恢复将移除本机对应学习库" }
            var records = 0, tombstones = 0
            snapshot.enumerateLines { line, _ in
                if !line.hasPrefix("#") { records += 1; if line.contains("\tc=-") { tombstones += 1 } }
            }
            return "\(label)：\(records) 条记录（含 \(tombstones) 条删除标记）"
        }.joined(separator: "\n")
    }
    func validate() throws {
        guard format == 1, rime == "1.17.0", Set(dictionaries.keys) == Set(Self.names) else { throw PersonalDataError("incompatible") }
        try settings.validate()
        for snapshot in dictionaries.values.compactMap({ $0 }) {
            guard snapshot.utf8.count <= 32 * 1024 * 1024, snapshot.hasPrefix("# Rime user dictionary\n"),
                  snapshot.hasSuffix("\n"), !snapshot.contains("\0"), !snapshot.contains("\r") else { throw PersonalDataError("snapshot") }
        }
    }
    static func read(_ url: URL) throws -> Self {
        let bytes = try PersonalDataFiles.read(url, limit: maximumBytes)
        let document = try JSONDecoder().decode(Self.self, from: bytes)
        // Codable ignores unknown fields by default. Require every nested field to survive encoding.
        let source = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary
        let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? NSDictionary
        guard let source, source == canonical else { throw PersonalDataError("unknown-fields") }
        try document.validate()
        return document
    }
}

enum PersonalDataFiles {
    static func safe(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard info.st_mode & S_IFMT != S_IFLNK else { throw PersonalDataError("symlink") }
            } else if errno != ENOENT { throw PersonalDataError("path-access") }
        }
    }
    static func read(_ url: URL, limit: Int) throws -> Data {
        try safe(url)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= limit else { throw PersonalDataError("file-size-or-type") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let bytes = try handle.read(upToCount: limit + 1), bytes.count <= limit else { throw PersonalDataError("size") }
        return bytes
    }
    static func directory(_ url: URL) throws {
        try safe(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func write(_ bytes: Data, _ url: URL) throws {
        try safe(url)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    static func exists(_ url: URL) throws -> Bool {
        try safe(url)
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw PersonalDataError("path-access")
    }
    @discardableResult static func validateTree(_ url: URL, maximumBytes: Int = 128 * 1024 * 1024) throws -> Int {
        try safe(url)
        var rootInfo = stat()
        guard lstat(url.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else { throw PersonalDataError("read-directory") }
        var readFailed = false
        guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey], errorHandler: { _, _ in readFailed = true; return false }) else { throw PersonalDataError("read-directory") }
        var bytes = 0, count = 0
        for case let entry as URL in entries {
            try safe(entry)
            let info = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            var native = stat()
            guard lstat(entry.path, &native) == 0, [S_IFREG, S_IFDIR].contains(native.st_mode & S_IFMT) else { throw PersonalDataError("file-type") }
            bytes += info.fileSize ?? 0; count += 1
            guard info.isSymbolicLink != true, bytes <= maximumBytes, count <= 10000 else { throw PersonalDataError("database-size") }
        }
        guard !readFailed else { throw PersonalDataError("read-directory") }
        return bytes
    }

    static func abandonedStaging(user: URL) throws -> [URL] {
        let staging = user.appendingPathComponent("PersonalData/staging")
        guard try exists(staging) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }
    static func cleanupStaging(_ roots: [URL]) {
        for root in roots {
            do { try validateTree(root, maximumBytes: 512 * 1024 * 1024); try FileManager.default.removeItem(at: root) }
            catch { /* Preserve ambiguous or unreadable artifacts; never follow links. */ }
        }
    }
}

package enum IFPersonalDataWorkerBootstrap {
    package static func run(arguments: [String]) -> Int32 {
        do {
            guard arguments.count == 3, arguments[1] == "--personal-data" else { throw PersonalDataError("arguments") }
            let request = URL(fileURLWithPath: arguments[2])
            let root = request.deletingLastPathComponent()
            try PersonalDataFiles.safe(root)
            guard request.lastPathComponent == "request.json", UUID(uuidString: root.lastPathComponent) != nil,
                  root.deletingLastPathComponent().lastPathComponent == "staging",
                  root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "PersonalData" else { throw PersonalDataError("staging") }
            let bytes = try PersonalDataFiles.read(request, limit: 256)
            guard let operation = String(data: bytes, encoding: .utf8), ["export", "restore"].contains(operation) else { throw PersonalDataError("operation") }
            let databaseRoot = root.appendingPathComponent("databases")
            try PersonalDataFiles.validateTree(databaseRoot)
            for name in PersonalBackupDocument.names {
                let database = databaseRoot.appendingPathComponent(name + ".userdb")
                let snapshot = root.appendingPathComponent(name + ".userdb.txt")
                if operation == "export" {
                    guard try PersonalDataFiles.exists(database) else { continue }
                } else {
                    guard try PersonalDataFiles.exists(snapshot) else { continue }
                    guard try !PersonalDataFiles.exists(database),
                          String(data: try PersonalDataFiles.read(snapshot, limit: 32 * 1024 * 1024), encoding: .utf8) != nil else { throw PersonalDataError("snapshot") }
                }
                try PersonalDataFiles.safe(snapshot)
                guard IFPersonalDataSnapshot(databaseRoot.path, name, snapshot.path, operation == "restore" ? 1 : 0) == 0 else { throw PersonalDataError("native-snapshot") }
            }
            return 0
        } catch {
            switch (error as? PersonalDataError)?.code {
            case "arguments", "operation": return 2
            case "staging", "symlink", "path-access": return 3
            case "snapshot", "size", "file-size-or-type": return 4
            case "native-snapshot": return 5
            case "database-size": return 6
            default: return 7
            }
        }
    }
}

struct PersonalDataWorker: Sendable {
    let user: URL
    let helper: URL
    func run(root: URL, restore: Bool) throws {
        try PersonalDataFiles.safe(root)
        guard root.deletingLastPathComponent() == user.appendingPathComponent("PersonalData/staging"),
              UUID(uuidString: root.lastPathComponent) != nil else { throw PersonalDataError("staging") }
        try PersonalDataFiles.write(Data((restore ? "restore" : "export").utf8), root.appendingPathComponent("request.json"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-D", "USER_ROOT=\(user.path)", "-D", "STORE_ROOT=\(user.appendingPathComponent("PersonalData").path)",
            "-D", "CANDIDATES_ROOT=\(root.deletingLastPathComponent().path)", "-D", "CANDIDATE_ROOT=\(root.path)",
            "-p", IFDictionaryWorkerRunner.sandboxProfile, helper.path, "--personal-data", root.appendingPathComponent("request.json").path]
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": root.path, "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        // Native diagnostics can contain dictionary text. Never collect or forward them.
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.1); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stages: [Int32: String] = [2: "request", 3: "path", 4: "snapshot", 5: "native-map", 6: "size", 7: "filesystem"]
            throw PersonalDataError("worker-" + (stages[process.terminationStatus] ?? "exit"))
        }
    }
}
