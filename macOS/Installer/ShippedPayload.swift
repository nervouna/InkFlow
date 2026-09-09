import Foundation
import Darwin

/// Owns only its fresh private extraction directory. No arbitrary archive input at runtime.
actor IFShippedPayload {
    private var root: URL?
    private var identity: IFFileIdentity?

    func load() throws -> IFUnpackedShippedCandidate {
        try clean()
        let bundle = IFFileSafety.canonicalTemporaryRoot(Bundle.main.bundleURL)
        let verifier = IFAppVerifier()
        // Verify sealed resources before reading metadata or invoking the extractor.
        _ = try verifier.code(at: bundle, identifier: "io.damao.inkflow.installer")
        let data = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String,
              [version, build].allSatisfy({ $0.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil }) else {
            throw IFInstallerError.invalid("安装器版本信息不完整，请重新获取安装器。")
        }
        let zip = bundle.appendingPathComponent("Contents/Resources/Payload/InkFlow.zip")
        try IFFileSafety.noLinks(zip)
        guard let stat = try IFFileSafety.info(zip), stat.st_mode & S_IFMT == S_IFREG else {
            throw IFInstallerError.invalid("安装器缺少内置安装包，请重新获取安装器。")
        }
        let parent = IFFileSafety.canonicalTemporaryRoot(FileManager.default.temporaryDirectory)
        try IFFileSafety.noLinks(parent)
        let folder = parent.appendingPathComponent("inkflow-payload-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else { throw IFInstallerError.filesystem("创建临时安装目录", errno) }
        root = folder
        identity = try IFFileIdentity(folder)
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, folder.path]
            // A file avoids pipe-buffer deadlocks while preserving bounded failure diagnostics.
            let log = folder.appendingPathComponent("extraction.log")
            guard FileManager.default.createFile(atPath: log.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw IFInstallerError.invalid("无法创建解包诊断文件。")
            }
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            process.standardOutput = output; process.standardError = output
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                // Only our extractor is terminated; no input-method process is touched.
                process.terminate()
                let stopDeadline = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw IFInstallerError.invalid("解包超时，请重试。")
            }
            guard process.terminationStatus == 0 else {
                let handle = try FileHandle(forReadingFrom: log)
                defer { try? handle.close() }
                let detail = String(decoding: try handle.read(upToCount: 8192) ?? Data(), as: UTF8.self)
                throw IFInstallerError.invalid("解包失败（\(process.terminationStatus)）：\(detail)")
            }
            try FileManager.default.removeItem(at: log)
            let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            guard entries == ["InkFlow.app"] else { throw IFInstallerError.invalid("安装包应仅包含 InkFlow.app。") }
            let candidate = IFUnpackedShippedCandidate(installerBundle: bundle,
                unpackedApp: folder.appendingPathComponent("InkFlow.app"), expectedVersion: .init(version: version, build: build))
            _ = try candidate.verify()
            return candidate
        } catch {
            do { try clean() }
            catch let cleanupError { throw IFInstallerError.invalid("准备安装失败：\(error)；临时文件清理失败：\(cleanupError)") }
            throw error
        }
    }

    func clean() throws {
        guard let root else { return }
        try IFFileSafety.noLinks(root)
        guard let identity, identity.matches(root) else {
            throw IFInstallerError.conflict("临时目录身份已改变，未删除：\(root.path)")
        }
        try FileManager.default.removeItem(at: root)
        self.root = nil; self.identity = nil
    }
}
