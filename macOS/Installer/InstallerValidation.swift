import Foundation
import Security
import Darwin

struct IFAppVersion: Codable, Equatable, Sendable {
    let version: String
    let build: String
    func isNewer(than other: Self) -> Bool {
        let order = version.compare(other.version, options: .numeric)
        return order == .orderedDescending || (order == .orderedSame && build.compare(other.build, options: .numeric) == .orderedDescending)
    }
}

struct IFVerifiedApp: Equatable, Sendable {
    let version: IFAppVersion
    let executable: String
    let codeHash: Data
}

enum IFInstallerError: Error, Equatable {
    case filesystem(String, Int32)
    case invalid(String)
    case conflict(String)
    case locked
    case recoveryRequired(String)
    case installedRecoveryRequired(String)
    case legacyEvidenceRequired(IFAppVersion)
    case terminationDeclined
    case terminationTimeout
    case cancelled
}

/// Reject symlinks in all existing path components, including dangling links.
enum IFFileSafety {
    /// Only Apple's known temporary-root aliases are canonicalized. App/state links remain errors.
    static func canonicalTemporaryRoot(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        for (alias, root) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if path == alias || path.hasPrefix(alias + "/") {
                return URL(fileURLWithPath: root + path.dropFirst(alias.count), isDirectory: url.hasDirectoryPath)
            }
        }
        return url.standardizedFileURL
    }

    static func info(_ url: URL) throws -> stat? {
        var value = stat()
        if lstat(url.path, &value) == 0 { return value }
        if errno == ENOENT { return nil }
        throw IFInstallerError.filesystem(url.path, errno)
    }
    static func noLinks(_ url: URL) throws {
        var part = canonicalTemporaryRoot(url)
        while part.path != "/" {
            if let value = try info(part), value.st_mode & S_IFMT == S_IFLNK {
                throw IFInstallerError.conflict("Symbolic link: \(part.path)")
            }
            part.deleteLastPathComponent()
        }
    }
    static func privateDirectory(_ url: URL) throws {
        try noLinks(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let value = try info(url), value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == getuid(), value.st_mode & 0o077 == 0 else {
            throw IFInstallerError.conflict("Installer state must be a current-user private directory: \(url.path)")
        }
    }
    static func tree(_ url: URL) throws {
        try noLinks(url)
        var traversalError: (any Error)?
        guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
            errorHandler: { _, error in traversalError = error; return false }) else {
            throw IFInstallerError.invalid("Unreadable bundle: \(url.path)")
        }
        for case let entry as URL in iterator {
            guard let value = try info(entry), [S_IFDIR, S_IFREG].contains(value.st_mode & S_IFMT) else {
                throw IFInstallerError.conflict("Unsupported bundle entry: \(entry.path)")
            }
        }
        if let traversalError { throw traversalError }
    }
}

/// Fixed production requirement; no ad-hoc/team-check bypass or shell codesign parsing.
struct IFAppVerifier: Sendable {
    static let team = "T7976FL2LP"
    static func requirement(identifier: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        let result = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard result == errSecSuccess, let requirement else { throw IFInstallerError.invalid("Code requirement: \(result)") }
        return requirement
    }
    func code(at url: URL, identifier: String) throws -> Data {
        var code: SecStaticCode?
        let create = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard create == errSecSuccess, let code else { throw IFInstallerError.invalid("Unsigned code: \(url.path) (\(create))") }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let result = SecStaticCodeCheckValidity(code, flags, try Self.requirement(identifier: identifier))
        guard result == errSecSuccess else { throw IFInstallerError.invalid("Signature verification: \(url.path) (\(result))") }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], values[kSecCodeInfoTeamIdentifier as String] as? String == Self.team,
              let hash = values[kSecCodeInfoUnique as String] as? Data else {
            throw IFInstallerError.invalid("Missing signed team/code identity")
        }
        return hash
    }
    func verify(_ url: URL) throws -> IFVerifiedApp {
        try IFFileSafety.tree(url)
        let hash = try code(at: url, identifier: IFInputIdentity.bundleID)
        // Read directly, avoiding Bundle's metadata cache after a path swap.
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == IFInputIdentity.bundleID,
              info["InputMethodConnectionName"] as? String == IFInputIdentity.connection,
              let modes = info["ComponentInputModeDict"] as? [String: Any],
              let modeEntries = modes["tsInputModeListKey"] as? [String: Any],
              modeEntries[IFInputIdentity.modeID] != nil,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String,
              [version, build].allSatisfy({ $0.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil }),
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != "..",
              let executableInfo = try IFFileSafety.info(url.appendingPathComponent("Contents/MacOS/" + executable)),
              executableInfo.st_mode & S_IFMT == S_IFREG else {
            throw IFInstallerError.invalid("Unexpected identity, mode, version or executable: \(url.path)")
        }
        return .init(version: .init(version: version, build: build), executable: executable, codeHash: hash)
    }
}

/// Task D unpacks only the shipped ZIP. Task B accepts its result, with outer and inner checks.
/// The outer bundle must still contain the sealed Payload/InkFlow.zip resource.
struct IFUnpackedShippedCandidate: Sendable {
    let installerBundle: URL
    let unpackedApp: URL
    let expectedVersion: IFAppVersion

    init(installerBundle: URL, unpackedApp: URL, expectedVersion: IFAppVersion) {
        self.installerBundle = IFFileSafety.canonicalTemporaryRoot(installerBundle)
        self.unpackedApp = IFFileSafety.canonicalTemporaryRoot(unpackedApp)
        self.expectedVersion = expectedVersion
    }

    func verify() throws -> IFVerifiedApp {

        let verifier = IFAppVerifier()
        _ = try verifier.code(at: installerBundle, identifier: "io.damao.inkflow.installer")
        let zip = installerBundle.appendingPathComponent("Contents/Resources/Payload/InkFlow.zip")
        try IFFileSafety.noLinks(zip)
        guard let value = try IFFileSafety.info(zip), value.st_mode & S_IFMT == S_IFREG else {
            throw IFInstallerError.invalid("Missing shipped ZIP resource")
        }
        let app = try verifier.verify(unpackedApp)
        guard app.version == expectedVersion else { throw IFInstallerError.invalid("Payload version/build mismatch") }
        return app
    }
}
