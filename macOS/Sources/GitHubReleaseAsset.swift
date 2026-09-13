import Foundation

struct IFGitHubReleaseAsset: Decodable, Sendable {
    let name: String
    let size: Int
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name, size
        case downloadURL = "browser_download_url"
    }
}
