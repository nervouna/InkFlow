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
        let files = try FileManager.default.subpathsOfDirectory(atPath: resources.path).filter { path in
            let url = resources.appendingPathComponent(path)
            if try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink {
                throw Failure("Bundle resource symlinks are unsupported by quality metadata")
            }
            var directory: ObjCBool = false
            return url != output && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
        }
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil)
        guard let info = info as? [String: Any], let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { throw Failure("Missing app version/build") }
        let bundledResourcesSHA256 = try digest(files, root: resources)
        if verify {
            guard try QualityBuildMetadataAccess.matches(Data(contentsOf: output), sourceRevision: identity.revision,
                sourceTreeSHA256: identity.digest, sourceDirty: identity.dirty,
                bundledResourcesSHA256: bundledResourcesSHA256, appVersion: version, appBuild: build) else {
                throw Failure("Quality build metadata does not match current source and bundled resources")
            }
            print("PASS quality build metadata: source revision/content and actual bundled resources")
        } else {
            try QualityBuildMetadataAccess.encoded(sourceRevision: identity.revision, sourceTreeSHA256: identity.digest,
                sourceDirty: identity.dirty, bundledResourcesSHA256: bundledResourcesSHA256,
                appVersion: version, appBuild: build).write(to: output, options: .atomic)
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
        let prefixes = ["macOS/Sources/", "macOS/SwiftPM/", "macOS/DictionaryWorker/", "macOS/DictionaryTool/", "macOS/Tools/", "macOS/Resources/",
            "macOS/Design/", "macOS/Data/", "macOS/config/", "macOS/Licenses/", "schemas/"]
        if prefixes.contains(where: path.hasPrefix) { return true }
        let scripts = ["build.sh", "build-icon.sh", "build-dictionary-generator.sh", "build-dictionary-worker.sh",
            "dependencies.sh", "prepare-rime.sh", "prepare-chinese.sh", "prepare-spelling.sh", "prepare-packaged-cache.sh",
            "quality-metadata.sh", "swift-package.sh"]
        if path.hasPrefix("macOS/scripts/") && scripts.contains(String(path.dropFirst("macOS/scripts/".count))) { return true }
        return false
    }

    private static func digest(_ paths: [String], root: URL) throws -> String {
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
                content = try Data(contentsOf: url)
            }
            // Length framing makes filenames/content boundaries unambiguous and excludes mtimes.
            hash.update(data: Data("\(path.utf8.count):\(path)\(kind):\(content.count):".utf8))
            hash.update(data: content)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
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
