import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

enum UpdateTests {
    @MainActor static func run() async throws {
        versionRules()
        releaseRules()
        scheduleRules()
        try launcherRules()
        try await transportRules()
        try await coordinatorRules()
        print("PASS updates: semantic versions, release assets, daily schedule, automatic-download orchestration, installer metadata, bounded download")
    }

    @MainActor private static func versionRules() {
        check(IFSemanticVersion("v1.2.3") == IFSemanticVersion("1.2.3"))
        check(IFSemanticVersion("1.2.4")! > IFSemanticVersion("1.2.3")!)
        check(IFSemanticVersion("1.3.0")! > IFSemanticVersion("1.2.99")!)
        check(IFSemanticVersion("2.0.0")! > IFSemanticVersion("1.99.99")!)
        check(IFSemanticVersion("1.2.3-beta") == nil, "Reject a non-release version")
    }

    @MainActor private static func releaseRules() {
        let valid = release(tag: "v1.2.3", assets: [
            asset("SHA256SUMS", size: 100, url: "https://github.com/nervouna/InkFlow/releases/download/v1.2.3/SHA256SUMS"),
            asset("InkFlow-1.2.3-9-arm64.dmg", size: 1234,
                  url: "https://github.com/nervouna/InkFlow/releases/download/v1.2.3/InkFlow-1.2.3-9-arm64.dmg"),
        ])
        let update = valid.availableUpdate(over: IFSemanticVersion("1.2.2")!)
        check(update?.version == IFSemanticVersion("1.2.3") && update?.assetName == "InkFlow-1.2.3-9-arm64.dmg")
        check(valid.availableUpdate(over: IFSemanticVersion("1.2.3")!) == nil, "The installed release is not offered again")
        check(release(tag: "v1.2.3", assets: [
            asset("InkFlow-1.2.3-9-arm64.dmg", size: 10, url: "https://example.com/private.dmg"),
        ]).availableUpdate(over: IFSemanticVersion("1.2.2")!) == nil,
              "Installer must come from the InkFlow GitHub release path")
    }

    @MainActor private static func scheduleRules() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        check(IFUpdateCheckSchedule.delay(lastCheck: nil, now: now) == 0)
        check(IFUpdateCheckSchedule.delay(lastCheck: now.addingTimeInterval(-86_400), now: now) == 0)
        check(IFUpdateCheckSchedule.delay(lastCheck: now.addingTimeInterval(-3_600), now: now) == 82_800)
    }

    @MainActor private static func launcherRules() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "inkflow-update-launcher-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appending(path: "InkFlow Installer.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "io.damao.inkflow.installer",
                                   "CFBundleShortVersionString": "1.2.3", "CFBundlePackageType": "APPL"]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contents.appending(path: "Info.plist"))
        let mount = try PropertyListSerialization.data(
            fromPropertyList: ["system-entities": [["mount-point": root.path]]], format: .xml, options: 0)
        let installer = try IFUpdateInstallerLauncher.installerURL(fromMountOutput: mount, version: IFSemanticVersion("1.2.3")!)
        check(installer == root.appending(path: "InkFlow Installer.app", directoryHint: .isDirectory))
        rejects { _ = try IFUpdateInstallerLauncher.installerURL(fromMountOutput: mount, version: IFSemanticVersion("1.2.4")!) }
    }

    @MainActor private static func transportRules() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "inkflow-update-download-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloadURL = URL(string: "https://github.com/nervouna/InkFlow/releases/download/v1.2.3/InkFlow-1.2.3-9-arm64.dmg")!
        let bytes = Data("dmg-fixture".utf8)
        UpdateStubURLProtocol.state.configure(release: releaseJSON(tag: "v1.2.3", assetName: "InkFlow-1.2.3-9-arm64.dmg",
                                                                   size: bytes.count, url: downloadURL), download: bytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateStubURLProtocol.self]
        let service = IFUpdateService(currentVersion: IFSemanticVersion("1.2.2")!,
                                      session: URLSession(configuration: configuration), cacheDirectory: root)
        let request = IFUpdateService.releaseRequest()
        check(request.url == IFUpdateService.releaseURL)
        let update = try await service.checkForUpdate()
        check(update?.byteCount == bytes.count && update?.downloadURL == downloadURL)
        guard let update else { check(false, "Expected available update"); return }
        let downloaded = try await service.download(update)
        let downloadedBytes = try Data(contentsOf: downloaded)
        check(downloadedBytes == bytes)
        try Data("old".utf8).write(to: root.appending(path: "InkFlow-old-arm64.dmg"))
        _ = try await service.download(update)
        check(!FileManager.default.fileExists(atPath: root.appending(path: "InkFlow-old-arm64.dmg").path),
              "Only the current cached installer remains")
    }

    @MainActor private static func coordinatorRules() async throws {
        let recorder = UpdateOperationRecorder()
        let update = IFAvailableUpdate(version: IFSemanticVersion("1.2.3")!, assetName: "InkFlow-1.2.3-9-arm64.dmg",
                                       byteCount: 10, downloadURL: URL(string: "https://github.com")!)
        let image = URL(fileURLWithPath: "/tmp/InkFlow-1.2.3-9-arm64.dmg")
        func coordinator(settings: IFSettings) -> IFUpdateCoordinator {
            IFUpdateCoordinator(settings: settings, checkForUpdate: {
                recorder.append("check")
                return update
            }, download: { received in
                recorder.append(received == update ? "download" : "download-wrong-update")
                return image
            }, openInstaller: { receivedImage, receivedVersion in
                recorder.append(receivedImage == image && receivedVersion == update.version ? "open" : "open-wrong-input")
            })
        }

        let checksOnly = IsolatedSettings()
        defer { checksOnly.cleanup() }
        let checksOnlyCoordinator = coordinator(settings: checksOnly.settings)
        checksOnlyCoordinator.start()
        try await Task.sleep(for: .milliseconds(20))
        check(recorder.events.isEmpty, "Default-off preference performs no request")
        checksOnly.settings.automaticUpdateChecksEnabled = true
        for _ in 0..<100 where checksOnly.settings.lastAutomaticUpdateCheck == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(recorder.events == ["check"], "Automatic checks do not download when automatic downloads are disabled")
        checksOnlyCoordinator.stop()

        let automaticDownload = IsolatedSettings()
        defer { automaticDownload.cleanup() }
        automaticDownload.settings.automaticUpdateDownloadsEnabled = true
        automaticDownload.settings.automaticUpdateChecksEnabled = true
        let downloadCoordinator = coordinator(settings: automaticDownload.settings)
        downloadCoordinator.start()
        for _ in 0..<100 where automaticDownload.settings.lastAutomaticUpdateCheck == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(automaticDownload.settings.lastAutomaticUpdateCheck != nil
              && recorder.events == ["check", "check", "download", "open"],
              "A due check downloads a newer release and opens its installer when both controls are enabled")
        automaticDownload.settings.candidateCount = 6
        try await Task.sleep(for: .milliseconds(20))
        check(recorder.events == ["check", "check", "download", "open"],
              "Unrelated settings changes do not restart update checks")
        downloadCoordinator.stop()
    }

    private static func release(tag: String, assets: [IFGitHubReleaseAsset]) -> IFGitHubRelease {
        IFGitHubRelease(tagName: tag, assets: assets)
    }

    private static func asset(_ name: String, size: Int, url: String) -> IFGitHubReleaseAsset {
        IFGitHubReleaseAsset(name: name, size: size, downloadURL: URL(string: url)!)
    }

    private static func releaseJSON(tag: String, assetName: String, size: Int, url: URL) -> Data {
        Data(#"{"tag_name":"\#(tag)","assets":[{"name":"\#(assetName)","size":\#(size),"browser_download_url":"\#(url.absoluteString)"}]}"#.utf8)
    }

    @MainActor private static func rejects(_ operation: () throws -> Void) {
        do { try operation(); check(false, "Expected update operation to fail") }
        catch { check(!error.localizedDescription.isEmpty) }
    }

}

final class UpdateOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ event: String) { lock.withLock { recorded.append(event) } }
    var events: [String] { lock.withLock { recorded } }
}

final class UpdateStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var release = Data()
    private var download = Data()

    func configure(release: Data, download: Data) {
        lock.withLock { self.release = release; self.download = download }
    }

    func bytes(for url: URL) -> Data {
        lock.withLock { url == IFUpdateService.releaseURL ? release : download }
    }
}

final class UpdateStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = UpdateStubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.state.bytes(for: url))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
