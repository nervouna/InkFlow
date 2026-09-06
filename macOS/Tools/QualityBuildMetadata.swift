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
        let revision = String(decoding: try git(["rev-parse", "HEAD"], root: root), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dirty = try !git(["status", "--porcelain", "--untracked-files=normal"], root: root).isEmpty
        let metadata = QualityBuildMetadata(sourceRevision: revision, sourceTreeSHA256: try digest(paths, root: root),
            sourceDirty: dirty, bundledResourcesSHA256: try digest(files, root: resources), appVersion: version, appBuild: build)
        if verify {
            let saved = try QualityJSON.decoder().decode(QualityBuildMetadata.self, from: Data(contentsOf: output))
            guard saved == metadata else { throw Failure("Quality build metadata does not match current source and bundled resources") }
            print("PASS quality build metadata: source revision/content and actual bundled resources")
        } else {
            try QualityJSON.encoder().encode(metadata).write(to: output, options: .atomic)
        }
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
