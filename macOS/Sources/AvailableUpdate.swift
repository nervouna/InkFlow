import Foundation

struct IFAvailableUpdate: Equatable, Sendable {
    let version: IFSemanticVersion
    let assetName: String
    let byteCount: Int
    let downloadURL: URL
}
