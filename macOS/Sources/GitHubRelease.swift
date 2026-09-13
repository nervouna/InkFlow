import Foundation

struct IFGitHubRelease: Decodable, Sendable {
    let tagName: String
    let assets: [IFGitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    func availableUpdate(over currentVersion: IFSemanticVersion) -> IFAvailableUpdate? {
        guard let version = IFSemanticVersion(tagName), version > currentVersion else { return nil }
        let prefix = "InkFlow-\(version)-"
        let matches = assets.filter { asset in
            asset.name.hasPrefix(prefix) && asset.name.hasSuffix("-arm64.dmg")
                && asset.size > 0 && asset.size <= IFUpdateService.maximumDownloadBytes
                && asset.downloadURL.scheme == "https" && asset.downloadURL.host == "github.com"
                && asset.downloadURL.path.hasPrefix("/nervouna/InkFlow/releases/download/")
        }
        guard matches.count == 1, let asset = matches.first else { return nil }
        return IFAvailableUpdate(version: version, assetName: asset.name, byteCount: asset.size,
                                 downloadURL: asset.downloadURL)
    }
}
