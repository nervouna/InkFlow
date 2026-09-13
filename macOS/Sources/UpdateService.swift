import Foundation

actor IFUpdateService {
    static let maximumDownloadBytes = 512 * 1024 * 1024
    static let releaseURL: URL = {
        guard let url = URL(string: "https://api.github.com/repos/nervouna/InkFlow/releases/latest") else {
            fatalError("InkFlow update endpoint is invalid")
        }
        return url
    }()

    private let currentVersion: IFSemanticVersion
    private let session: URLSession
    private let cacheDirectory: URL

    init(currentVersion: IFSemanticVersion, session: URLSession? = nil,
         cacheDirectory: URL = .cachesDirectory.appending(path: "InkFlow/Updates", directoryHint: .isDirectory)) {
        self.currentVersion = currentVersion
        self.cacheDirectory = cacheDirectory
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 15 * 60
            self.session = URLSession(configuration: configuration)
        }
    }

    static func releaseRequest() -> URLRequest {
        var request = URLRequest(url: releaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("InkFlow-Update", forHTTPHeaderField: "User-Agent")
        return request
    }

    func checkForUpdate() async throws -> IFAvailableUpdate? {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: Self.releaseRequest())
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let release = try JSONDecoder().decode(IFGitHubRelease.self, from: data)
        return release.availableUpdate(over: currentVersion)
    }

    func download(_ update: IFAvailableUpdate) async throws -> URL {
        guard update.byteCount > 0, update.byteCount <= Self.maximumDownloadBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        try Task.checkCancellation()
        let (temporaryURL, response) = try await session.download(from: update.downloadURL)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize,
              fileSize > 0, fileSize <= Self.maximumDownloadBytes else {
            throw URLError(.cannotDecodeContentData)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let destination = cacheDirectory.appending(path: update.assetName, directoryHint: .notDirectory)
        for item in try manager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.isRegularFileKey]) {
            guard item.pathExtension == "dmg",
                  try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try manager.removeItem(at: item)
        }
        try manager.moveItem(at: temporaryURL, to: destination)
        return destination
    }
}
