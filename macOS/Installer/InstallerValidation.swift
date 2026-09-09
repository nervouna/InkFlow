import Foundation

struct IFAppVersion: Equatable, Sendable {
    let version: String
    let build: String
}

enum IFInstallerError: Error, Equatable {
    case filesystem(String, Int32)
    case invalid(String)
    case terminationDeclined
    case terminationTimeout
    case cancelled
}

struct IFUnpackedShippedCandidate: Sendable {
    let unpackedApp: URL
    let expectedVersion: IFAppVersion
}
