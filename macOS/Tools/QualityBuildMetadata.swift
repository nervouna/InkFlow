import Foundation
import CryptoKit
#if SWIFT_PACKAGE
import InkFlowCore
#endif

/// Build-time only: stamps actual working-tree bytes and the resources copied into this bundle.
@main
struct QualityBuildMetadataTool {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Quality metadata: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        guard CommandLine.arguments.count >= 3 else { throw Failure("Usage: quality-build-metadata <repository> <app> [--verify] | <repository> --build-snapshot") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let identity = try buildIdentity(root: root)
        if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--build-snapshot" {
            print("\(identity.revision) \(identity.dirty ? "dirty" : "clean") \(identity.digest)")
            return
        }
        guard (3...4).contains(CommandLine.arguments.count) else { throw Failure("Invalid quality metadata arguments") }
        let app = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let resources = app.appendingPathComponent("Contents/Resources")
        let output = resources.appendingPathComponent("QualityBuild.json")
        let verify = CommandLine.arguments.count == 4
        guard !verify || CommandLine.arguments[3] == "--verify" else { throw Failure("Unknown metadata option") }
        let resourceFiles = try regularFiles(root: resources, excluding: [output])
        let bundleFiles = try regularFiles(root: app, excluding: [output], excludingCodeSignatureArtifacts: true)
        let rankingSources = try manifest(root.appendingPathComponent("macOS/Quality/ranking-sources.txt"), root: root,
                                          requireTracked: true)
        let rankingResources = try manifest(root.appendingPathComponent("macOS/Quality/ranking-resources.txt"), root: resources,
                                            requireTracked: false)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil)
        guard let info = info as? [String: Any], let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { throw Failure("Missing app version/build") }
        let metadata = try QualityBuildMetadataAccess.encoded(sourceRevision: identity.revision, sourceTreeSHA256: identity.digest,
            sourceDirty: identity.dirty, bundledResourcesSHA256: try digest(resourceFiles, root: resources),
            bundleSHA256: try digest(bundleFiles, root: app, canonicalizingCodeSignatures: true),
            rankingSourceSHA256: try digest(rankingSources, root: root),
            rankingResourcesSHA256: try digest(rankingResources, root: resources), appVersion: version, appBuild: build)
        if verify {
            let saved = try Data(contentsOf: output)
            guard saved == metadata else { throw Failure("Quality build metadata does not match current source and bundled resources") }
            print("PASS quality build metadata: full build and audited ranking inputs")
        } else {
            try metadata.write(to: output, options: .atomic)
        }
    }

    private static func buildIdentity(root: URL) throws -> (revision: String, dirty: Bool, digest: String) {
        let all = try git(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], root: root)
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var paths = all.filter(isBuildInput)
        for dependency in ["build/deps/librime.tar.bz2", "build/deps/pinyin.tar.gz", "build/deps/english.tar.gz", "build/deps/emoji.txt"] {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(dependency).path) { paths.append(dependency) }
        }
        let dictionarySources = root.appendingPathComponent("build/dictionary-sources")
        if let children = try? FileManager.default.subpathsOfDirectory(atPath: dictionarySources.path) {
            paths += children.compactMap { child in
                var directory: ObjCBool = false
                let relative = "build/dictionary-sources/\(child)"
                return FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path, isDirectory: &directory)
                    && !directory.boolValue ? relative : nil
            }
        }
        let revision = String(decoding: try git(["rev-parse", "HEAD"], root: root), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try git(["status", "--porcelain=v1", "--untracked-files=normal", "-z"], root: root)
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let dirty = status.contains { entry in
            entry.count > 3 && isBuildInput(String(entry.dropFirst(3)))
        }
        return (revision, dirty, try digest(paths, root: root))
    }

    private static func isBuildInput(_ path: String) -> Bool {
        if ["Package.swift", "macOS/Info.plist"].contains(path) { return true }
        let prefixes = ["macOS/Sources/", "macOS/Quality/", "macOS/SwiftPM/", "macOS/DictionaryWorker/", "macOS/DictionaryTool/", "macOS/Tools/", "macOS/Resources/",
            "macOS/Design/", "macOS/Data/", "macOS/config/", "macOS/Licenses/", "schemas/"]
        if prefixes.contains(where: path.hasPrefix) { return true }
        let scripts = ["build.sh", "build-icon.sh", "build-dictionary-generator.sh", "build-dictionary-worker.sh",
            "dependencies.sh", "prepare-rime.sh", "prepare-chinese.sh", "prepare-spelling.sh", "prepare-packaged-cache.sh",
            "quality-metadata.sh", "swift-package.sh"]
        if path.hasPrefix("macOS/scripts/") && scripts.contains(String(path.dropFirst("macOS/scripts/".count))) { return true }
        return false
    }

    private static func regularFiles(root: URL, excluding: Set<URL>,
                                     excludingCodeSignatureArtifacts: Bool = false) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: root.path).compactMap { path in
            if excludingCodeSignatureArtifacts && (path.split(separator: "/").contains("_CodeSignature")
                || path == "Contents/CodeResources") {
                return nil
            }
            let url = root.appendingPathComponent(path).standardizedFileURL
            if excluding.contains(url) { return nil }
            let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeSymbolicLink { throw Failure("Bundle symlinks are unsupported by quality metadata: \(path)") }
            return type == .typeRegular ? path : nil
        }
    }

    private static func manifest(_ url: URL, root: URL, requireTracked: Bool) throws -> [String] {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw Failure("Missing ranking manifest: \(url.path)") }
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: { $0.isNewline }).map(String.init)
        let entries = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !entries.isEmpty else { throw Failure("Empty ranking manifest: \(url.path)") }
        guard Set(entries).count == entries.count else { throw Failure("Duplicate entry in ranking manifest: \(url.path)") }
        for path in entries {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw Failure("Unsafe ranking manifest path: \(path)")
            }
            let file = root.appendingPathComponent(path).standardizedFileURL
            guard file.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw Failure("Missing ranking manifest file: \(path)")
            }
            if requireTracked {
                let relative = file.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
                _ = try git(["ls-files", "--error-unmatch", "--", relative], root: root)
            }
        }
        return entries
    }

    private static func digest(_ paths: [String], root: URL,
                               canonicalizingCodeSignatures: Bool = false) throws -> String {
        var hash = SHA256()
        for path in Set(paths).sorted() {
            let url = root.appendingPathComponent(path)
            let content: Data
            let kind: String
            if !FileManager.default.fileExists(atPath: url.path) {
                // A tracked deletion is part of a dirty source tree.
                kind = "missing"
                content = Data()
            } else if try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink {
                kind = "symlink"
                content = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
            } else {
                kind = "file"
                let bytes = try Data(contentsOf: url)
                content = canonicalizingCodeSignatures ? try unsignedMachO(bytes, path: path) : bytes
            }
            // Length framing makes filenames/content boundaries unambiguous and excludes mtimes.
            hash.update(data: Data("\(path.utf8.count):\(path)\(kind):\(content.count):".utf8))
            hash.update(data: content)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Code signing replaces only Mach-O signature blobs and adds `_CodeSignature` files.
    /// Hash the complete unsigned payload so the build-stamped identity survives later
    /// ad-hoc or Developer ID signing without omitting executable code bytes.
    private static func unsignedMachO(_ data: Data, path: String) throws -> Data {
        let magics: Set<[UInt8]> = [
            [0xce, 0xfa, 0xed, 0xfe], [0xcf, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xce], [0xfe, 0xed, 0xfa, 0xcf],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
        ]
        guard data.count >= 4, magics.contains(Array(data.prefix(4))) else { return data }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkflow-quality-macho-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--remove-signature", temporary.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("Cannot canonicalize Mach-O code signature: \(path)")
        }
        let validation = Process()
        validation.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        validation.arguments = ["lipo", "-info", temporary.path]
        validation.standardOutput = FileHandle.nullDevice
        validation.standardError = FileHandle.nullDevice
        try validation.run()
        validation.waitUntilExit()
        guard validation.terminationStatus == 0 else {
            throw Failure("Invalid Mach-O while calculating bundle identity: \(path)")
        }
        return try Data(contentsOf: temporary)
    }

    private static func git(_ arguments: [String], root: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("Cannot read build source identity from Git") }
        return data
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
