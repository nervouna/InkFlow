import Foundation
import CryptoKit

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
        guard (3...4).contains(CommandLine.arguments.count) else {
            throw Failure("Usage: quality-build-metadata <repository> <app> [--verify]")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let app = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let resources = app.appendingPathComponent("Contents/Resources")
        let output = resources.appendingPathComponent("QualityBuild.json")
        let verify = CommandLine.arguments.count == 4
        guard !verify || CommandLine.arguments[3] == "--verify" else { throw Failure("Unknown metadata option") }
        let paths = try git(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], root: root)
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let resourceFiles = try regularFiles(root: resources, excluding: [output])
        let bundleFiles = try regularFiles(root: app, excluding: [output])
        let rankingSources = try manifest(root.appendingPathComponent("macOS/Quality/ranking-sources.txt"), root: root,
                                          requireTracked: true)
        let rankingResources = try manifest(root.appendingPathComponent("macOS/Quality/ranking-resources.txt"), root: resources,
                                            requireTracked: false)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil)
        guard let info = info as? [String: Any], let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { throw Failure("Missing app version/build") }
        let revision = String(decoding: try git(["rev-parse", "HEAD"], root: root), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dirty = try !git(["status", "--porcelain", "--untracked-files=normal"], root: root).isEmpty
        let metadata = QualityBuildMetadata(sourceRevision: revision, sourceTreeSHA256: try digest(paths, root: root),
            sourceDirty: dirty, bundledResourcesSHA256: try digest(resourceFiles, root: resources),
            bundleSHA256: try digest(bundleFiles, root: app), rankingSourceSHA256: try digest(rankingSources, root: root),
            rankingResourcesSHA256: try digest(rankingResources, root: resources), appVersion: version, appBuild: build)
        if verify {
            let saved = try QualityJSON.decoder().decode(QualityBuildMetadata.self, from: Data(contentsOf: output))
            guard saved == metadata else { throw Failure("Quality build metadata does not match current source and bundled resources") }
            print("PASS quality build metadata: full build and audited ranking inputs")
        } else {
            try QualityJSON.encoder().encode(metadata).write(to: output, options: .atomic)
        }
    }

    private static func regularFiles(root: URL, excluding: Set<URL>) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: root.path).compactMap { path in
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
