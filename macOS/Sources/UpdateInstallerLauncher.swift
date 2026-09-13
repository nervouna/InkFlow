import AppKit

actor IFUpdateInstallerLauncher {
    func openInstaller(from diskImage: URL, version: IFSemanticVersion) async throws {
        let mountData = try await mount(diskImage)
        try Task.checkCancellation()
        let installer = try Self.installerURL(fromMountOutput: mountData, version: version)
        try await Self.openApplication(at: installer)
    }

    static func installerURL(fromMountOutput data: Data, version: IFSemanticVersion) throws -> URL {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let candidates = entities.compactMap { $0["mount-point"] as? String }.map {
            URL(fileURLWithPath: $0, isDirectory: true).appending(path: "InkFlow Installer.app", directoryHint: .isDirectory)
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard candidates.count == 1, let installer = candidates.first, let bundle = Bundle(url: installer),
              bundle.bundleIdentifier == "io.damao.inkflow.installer",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version.description else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return installer
    }

    private func mount(_ diskImage: URL) async throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-readonly", "-nobrowse", "-plist", diskImage.path]
        process.standardOutput = output
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { completed in
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    if completed.terminationStatus == 0 {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    }
                }
                do { try process.run() }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
    }

    @MainActor
    private static func openApplication(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
