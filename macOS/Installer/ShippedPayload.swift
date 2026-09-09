import Foundation

/// Extract only the installer's embedded archive. Signing is release QA's responsibility.
actor IFShippedPayload {
    private var root: URL?

    func load() throws -> IFUnpackedShippedCandidate {
        try clean()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkflow-payload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        root = folder
        let zip = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Payload/InkFlow.zip")
        let log = folder.appendingPathComponent("extraction.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        process.standardOutput = output; process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw IFInstallerError.invalid("解包失败（\(process.terminationStatus)）：\(detail)")
        }
        let app = folder.appendingPathComponent("InkFlow.app")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: app.path, isDirectory: &directory), directory.boolValue else {
            throw IFInstallerError.invalid("安装包缺少 InkFlow.app。")
        }
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        return .init(unpackedApp: app, expectedVersion: .init(
            version: info["CFBundleShortVersionString"] as? String ?? "未知",
            build: info["CFBundleVersion"] as? String ?? "未知"))
    }

    func clean() throws {
        guard let root else { return }
        try FileManager.default.removeItem(at: root)
        self.root = nil
    }
}
