import Foundation
import CryptoKit
import Darwin

/// All paths originate locally; no source-supplied path is ever joined to a filesystem root.
enum IFDictionaryFiles {
    /// Foundation collapses /private aliases differently before and after creation; use filesystem identity instead.
    static func canonical(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
    static func child(_ relative: String, in root: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw IFDictionaryUpdateError(.recovery, "unsafe-path")
        }
        var url = try canonical(root)
        for part in parts {
            url.appendPathComponent(String(part))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw IFDictionaryUpdateError(.recovery, "symlink-path", file: relative)
            }
        }
        return url
    }
    static func hashes(in root: URL, excluding: Set<String> = []) throws -> [String: String] {
        let root = try canonical(root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw IFDictionaryUpdateError(.prepare, "missing-resources")
        }
        var result = [String: String]()
        for case let file as URL in enumerator {
            let relative = String(try canonical(file).path.dropFirst(root.path.count + 1))
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw IFDictionaryUpdateError(.prepare, "symlink-resource", file: relative) }
            if values.isRegularFile == true, !excluding.contains(relative) {
                result[relative] = try hash(file)
            }
        }
        return result
    }
    static func hash(_ url: URL) throws -> String {
        guard try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw IFDictionaryUpdateError(.verify, "nonregular-file") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let file = try FileHandle(forWritingTo: temporary)
        do { try file.synchronize(); try file.close() } catch { try? file.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // The rename is the commit boundary. A subsequent durability hint cannot report an uncommitted transaction.
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        if descriptor >= 0 { _ = fsync(descriptor); close(descriptor) }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
}

struct IFDictionaryRuntime: Sendable {
    let resources: URL
    let helper: URL
    let libraries: [URL]
    func fingerprint() throws -> String {
        var files = try IFDictionaryFiles.hashes(in: resources, excluding: [IFDictionaryCatalog.dictionaryFilename,
            IFDictionaryManifest.filename, IFDictionaryCatalog.legacyFilename])
        files["@helper"] = try IFDictionaryFiles.hash(helper)
        for (offset, library) in libraries.enumerated() { files["@library/\(offset)/\(library.lastPathComponent)"] = try IFDictionaryFiles.hash(library) }
        return IFDictionaryHash.sha256(try IFDictionaryFiles.encode(files))
    }
}
struct IFDictionaryVersion: Codable, Equatable, Sendable {
    let contentVersion: String
    let runtimeFingerprint: String
    let artifactID: String
    let preparedAt: Date
    var activatedAt: Date?
init(contentVersion: String, runtimeFingerprint: String, preparedAt: Date, activatedAt: Date? = nil,
         artifactID: String = UUID().uuidString.lowercased()) {
        self.contentVersion = contentVersion; self.runtimeFingerprint = runtimeFingerprint; self.preparedAt = preparedAt
        self.activatedAt = activatedAt; self.artifactID = artifactID
    }
    var directory: String { "versions/\(contentVersion)-\(runtimeFingerprint)-\(artifactID)" }
    func validate() throws {
        let prefix = "r\(IFDictionaryCatalog.recipeVersion)-"
        guard contentVersion.hasPrefix(prefix), IFDictionaryHash.isHex(String(contentVersion.dropFirst(prefix.count)), length: 64),
              IFDictionaryHash.isHex(runtimeFingerprint, length: 64), UUID(uuidString: artifactID) != nil else { throw IFDictionaryUpdateError(.recovery, "invalid-version") }
    }
}
struct IFDictionaryBundledActivation: Codable, Equatable, Sendable {
    let contentVersion: String
    let activatedAt: Date
}
struct IFDictionaryState: Codable, Equatable, Sendable {
    var formatVersion = 1
    var current: IFDictionaryVersion?
    var previous: IFDictionaryVersion?
    var pending: IFDictionaryVersion?
    var transaction: IFDictionaryStage?
    var bundled: IFDictionaryBundledActivation?
}
struct IFDictionaryPreparedReceipt: Codable, Sendable {
    static let filename = "prepared.json"
    let contentVersion: String
    let runtimeFingerprint: String
    let files: [String: String]
}
struct IFDictionaryDescriptor: Sendable {
    let version: IFDictionaryVersion?
    let manifest: IFDictionaryManifest
    let sharedData: URL
    let cache: URL?
}

/// The update coordinator serializes mutations. Atomic state always keeps the last confirmed pointer.
struct IFDictionaryStore: Sendable {
    let root: URL
    var beforeStateWrite: @Sendable (IFDictionaryState) throws -> Void = { _ in }
    init(root: URL, beforeStateWrite: @escaping @Sendable (IFDictionaryState) throws -> Void = { _ in }) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = try IFDictionaryFiles.canonical(root); self.beforeStateWrite = beforeStateWrite
        for name in ["versions", "candidates"] {
            try FileManager.default.createDirectory(at: IFDictionaryFiles.child(name, in: self.root), withIntermediateDirectories: true)
        }
    }
    func state() throws -> IFDictionaryState {
        let url = try IFDictionaryFiles.child("state.json", in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let state = try IFDictionaryFiles.decode(IFDictionaryState.self, at: url)
        guard state.formatVersion == 1, !(state.current != nil && state.bundled != nil),
              (state.pending == nil && state.transaction == nil) || (state.pending != nil && state.transaction == .apply) else {
            throw IFDictionaryUpdateError(.recovery, "invalid-state")
        }
        try [state.current, state.previous, state.pending].compactMap { $0 }.forEach { try $0.validate() }
        if let bundled = state.bundled {
            try IFDictionaryVersion(contentVersion: bundled.contentVersion, runtimeFingerprint: String(repeating: "0", count: 64), preparedAt: bundled.activatedAt).validate()
        }
        return state
    }
    private func save(_ state: IFDictionaryState) throws {
        try beforeStateWrite(state)
        try IFDictionaryFiles.atomicWrite(IFDictionaryFiles.encode(state), to: IFDictionaryFiles.child("state.json", in: root))
    }
    func candidate() throws -> URL {
        let url = try IFDictionaryFiles.child("candidates/\(UUID().uuidString.lowercased())", in: root)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func removeCandidate(_ url: URL) throws {
        guard url.deletingLastPathComponent().path == root.appendingPathComponent("candidates").path, UUID(uuidString: url.lastPathComponent) != nil,
              url.path == (try IFDictionaryFiles.canonical(url)).path else { throw IFDictionaryUpdateError(.prepare, "unsafe-candidate") }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private struct Observation: Codable { let contentVersion: String; let receipts: [IFDictionarySourceReceipt] }
    /// Save only after generation proves the sources produce the currently active content.
    func recordContentUnchanged(_ manifest: IFDictionaryManifest, activeContentVersion: String) throws {
        guard manifest.contentVersion == activeContentVersion, manifest.sources.map(\.id) == IFDictionaryCatalog.sources.map(\.id) else {
            throw IFDictionaryUpdateError(.check, "observation-content")
        }
        try IFDictionaryFiles.atomicWrite(IFDictionaryFiles.encode(Observation(contentVersion: activeContentVersion, receipts: manifest.sources)),
                                          to: IFDictionaryFiles.child("observed.json", in: root))
    }
    func observed(active: IFDictionaryManifest) throws -> [IFDictionarySourceReceipt] {
        let url = try IFDictionaryFiles.child("observed.json", in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return active.sources }
        let observation = try IFDictionaryFiles.decode(Observation.self, at: url)
        guard observation.contentVersion == active.contentVersion else { return active.sources }
        guard observation.receipts.map(\.id) == IFDictionaryCatalog.sources.map(\.id) else { throw IFDictionaryUpdateError(.check, "source-set") }
        return observation.receipts
    }
    func adopt(_ candidate: URL, fingerprint: String, now: Date = Date()) throws -> IFDictionaryVersion {
        guard candidate.deletingLastPathComponent().path == root.appendingPathComponent("candidates").path, UUID(uuidString: candidate.lastPathComponent) != nil,
              candidate.path == (try IFDictionaryFiles.canonical(candidate)).path else { throw IFDictionaryUpdateError(.prepare, "unsafe-candidate") }
        let manifest = try validatedManifest(at: candidate.appendingPathComponent("shared"))
        let version = IFDictionaryVersion(contentVersion: manifest.contentVersion, runtimeFingerprint: fingerprint, preparedAt: now)
        try version.validate(); try validatePrepared(at: candidate, version: version)
        let destination = try IFDictionaryFiles.child(version.directory, in: root)
        try FileManager.default.moveItem(at: candidate, to: destination)
        return version
    }
    func resolve(_ version: IFDictionaryVersion, fingerprint: String) throws -> IFDictionaryDescriptor {
        try version.validate()
        guard version.runtimeFingerprint == fingerprint else { throw IFDictionaryUpdateError(.prepare, "runtime-changed") }
        let directory = try IFDictionaryFiles.child(version.directory, in: root)
        try validatePrepared(at: directory, version: version)
        return .init(version: version, manifest: try validatedManifest(at: directory.appendingPathComponent("shared")),
                     sharedData: directory.appendingPathComponent("shared"), cache: directory.appendingPathComponent("cache"))
    }
    /// Inert source data for rebuilding with CURRENT app-owned schemas, Lua and correction policy.
    func storedDictionary(_ version: IFDictionaryVersion) throws -> URL {
        try version.validate()
        let directory = try IFDictionaryFiles.child(version.directory + "/shared", in: root)
        let manifest = try validatedManifest(at: directory)
        guard manifest.contentVersion == version.contentVersion else { throw IFDictionaryUpdateError(.recovery, "manifest-version") }
        return directory
    }
    func bundled(_ resources: URL) throws -> IFDictionaryDescriptor {
        .init(version: nil, manifest: try validatedManifest(at: resources), sharedData: resources, cache: nil)
    }
    func beginActivation(_ version: IFDictionaryVersion) throws {
        _ = try resolve(version, fingerprint: version.runtimeFingerprint)
        try beginValidatedActivation(version)
    }
    /// Caller already resolved the immutable artifact in this serialized operation. Compact journal write only.
    func beginValidatedActivation(_ version: IFDictionaryVersion) throws {
        try version.validate()
        var state = try state()
        guard state.pending == nil else { throw IFDictionaryUpdateError(.apply, "activation-in-progress") }
        state.pending = version; state.transaction = .apply; try save(state)
    }
    func confirmActivation(_ version: IFDictionaryVersion, now: Date = Date()) throws {
        var state = try state()
        guard state.pending == version, state.transaction == .apply else { throw IFDictionaryUpdateError(.apply, "activation-mismatch") }
        var confirmed = version; confirmed.activatedAt = now
        state.previous = state.current; state.current = confirmed; state.bundled = nil; state.pending = nil; state.transaction = nil
        try save(state)
    }
    func abandonActivation() throws {
        var state = try state(); state.pending = nil; state.transaction = nil; try save(state)
    }
    /// Never retries interrupted pending work. T3 selects fallback when confirmed cache is unavailable.
    func recoverInterrupted() throws -> IFDictionaryState {
        var state = try state()
        if state.pending != nil { state.pending = nil; state.transaction = nil; try save(state) }
        return state
    }
    func confirmFallback(_ version: IFDictionaryVersion) throws {
        _ = try resolve(version, fingerprint: version.runtimeFingerprint)
        try confirmValidatedFallback(version)
    }
    /// Caller has validated the artifact and successfully started its engine/sessions. No cache hashing here.
    func confirmValidatedFallback(_ version: IFDictionaryVersion) throws {
        try version.validate()
        var state = try state(); state.current = version; state.bundled = nil; state.pending = nil; state.transaction = nil
        try save(state)
    }
    func confirmBundled(_ manifest: IFDictionaryManifest, now: Date = Date()) throws {
        var state = try state(); state.current = nil; state.pending = nil; state.transaction = nil
        if state.bundled?.contentVersion != manifest.contentVersion {
            state.bundled = .init(contentVersion: manifest.contentVersion, activatedAt: now)
        }
        try save(state)
    }
    /// Repair an unreadable journal only after the bundled engine has actually started.
    func repairBundled(_ manifest: IFDictionaryManifest, now: Date = Date()) throws {
        try Self.validateMetadata(manifest)
        var fresh = IFDictionaryState()
        fresh.bundled = .init(contentVersion: manifest.contentVersion, activatedAt: now)
        try save(fresh)
    }

    /// Bounded housekeeping within the owned store. Never visits the learning/custom-phrase root.
    /// Serialize with other store mutations and run off MainActor while input is served.
    @discardableResult
    func cleanup(limit: Int = 32) throws -> Int {
        let state = try state()
        let retained = Set([state.current, state.previous, state.pending].compactMap { $0?.directory })
        var removed = 0
        for name in ["candidates", "versions"] {
            let folder = try IFDictionaryFiles.child(name, in: root)
            let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard removed < max(0, limit) else { return removed }
                let relative = name + "/" + entry.lastPathComponent
                guard !retained.contains(relative) else { continue }
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let valid: Bool
                if name == "candidates" { valid = UUID(uuidString: entry.lastPathComponent) != nil }
                else {
                    // version directory = rN-contentSHA-runtimeSHA-UUID, all generated locally.
                    let parts = entry.lastPathComponent.split(separator: "-", maxSplits: 3).map(String.init)
                    valid = parts.count == 4 && parts[0] == "r\(IFDictionaryCatalog.recipeVersion)" &&
                        IFDictionaryHash.isHex(parts[1], length: 64) && IFDictionaryHash.isHex(parts[2], length: 64) &&
                        UUID(uuidString: parts[3]) != nil
                }
                guard valid else { continue }
                try FileManager.default.removeItem(at: IFDictionaryFiles.child(relative, in: root))
                removed += 1
            }
        }
        return removed
    }

    static func validateMetadata(_ manifest: IFDictionaryManifest) throws {
        try IFDictionaryVersion(contentVersion: manifest.contentVersion, runtimeFingerprint: String(repeating: "0", count: 64), preparedAt: .distantPast).validate()
        guard manifest.formatVersion == 1, manifest.recipeVersion == IFDictionaryCatalog.recipeVersion, manifest.entryCount > 0,
              IFDictionaryHash.isHex(manifest.contentSHA256, length: 64), IFDictionaryHash.isHex(manifest.dictionarySHA256, length: 64),
              IFDictionaryHash.isHex(manifest.correctionsSHA256, length: 64),
              manifest.sources.map(\.id) == IFDictionaryCatalog.sources.map(\.id) else { throw IFDictionaryUpdateError(.verify, "manifest-metadata") }
        for (receipt, spec) in zip(manifest.sources, IFDictionaryCatalog.sources) {
            guard receipt.name == spec.name, receipt.repository == spec.repository, receipt.path == spec.path,
                  IFDictionaryHash.isHex(receipt.commit, length: 40), IFDictionaryHash.isHex(receipt.blobSHA, length: 40),
                  IFDictionaryHash.isHex(receipt.sha256, length: 64), receipt.byteCount > 0,
                  receipt.byteCount <= IFDictionaryCatalog.maximumSourceBytes, receipt.recordCount > 0 else {
                throw IFDictionaryUpdateError(.verify, "manifest-source", source: spec.id)
            }
            if !spec.isUpdatable {
                guard receipt.commit == spec.pinnedCommit, receipt.blobSHA == spec.pinnedBlobSHA, receipt.sha256 == spec.pinnedSHA256 else {
                    throw IFDictionaryUpdateError(.verify, "manifest-legacy", source: spec.id)
                }
            }
        }
    }
    func validatedManifest(at shared: URL) throws -> IFDictionaryManifest {
        let manifest = try IFDictionaryFiles.decode(IFDictionaryManifest.self, at: IFDictionaryFiles.child(IFDictionaryManifest.filename, in: shared))
        try Self.validateMetadata(manifest)
        guard try IFDictionaryFiles.hash(IFDictionaryFiles.child(IFDictionaryCatalog.dictionaryFilename, in: shared)) == manifest.dictionarySHA256 else {
            throw IFDictionaryUpdateError(.verify, "manifest-integrity")
        }
        return manifest
    }
    private func validatePrepared(at directory: URL, version: IFDictionaryVersion) throws {
        let receipt = try IFDictionaryFiles.decode(IFDictionaryPreparedReceipt.self, at: IFDictionaryFiles.child(IFDictionaryPreparedReceipt.filename, in: directory))
        let required = ["shared/\(IFDictionaryManifest.filename)", "shared/\(IFDictionaryCatalog.dictionaryFilename)",
                        "cache/inkflow_pinyin.schema.yaml", "cache/pinyin_simp.table.bin", "cache/pinyin_simp.prism.bin",
                        "cache/easy_en.table.bin", "cache/inkflow_mixed.table.bin"]
        guard receipt.contentVersion == version.contentVersion, receipt.runtimeFingerprint == version.runtimeFingerprint else {
            throw IFDictionaryUpdateError(.verify, "prepared-version")
        }
        for path in required where receipt.files[path] == nil {
            throw IFDictionaryUpdateError(.verify, "prepared-file-missing", file: path)
        }
        guard receipt.files.keys.allSatisfy({ $0.hasPrefix("shared/") || $0.hasPrefix("cache/") || $0.hasPrefix("raw/") }) else {
            throw IFDictionaryUpdateError(.verify, "prepared-path")
        }
        for (path, hash) in receipt.files {
            guard IFDictionaryHash.isHex(hash, length: 64), try IFDictionaryFiles.hash(IFDictionaryFiles.child(path, in: directory)) == hash else {
                throw IFDictionaryUpdateError(.verify, "prepared-checksum", file: path)
            }
        }
        var actualCount = 0
        for name in ["shared", "cache", "raw"] {
            let folder = try IFDictionaryFiles.child(name, in: directory)
            if FileManager.default.fileExists(atPath: folder.path) { actualCount += try IFDictionaryFiles.hashes(in: folder).count }
        }
        guard actualCount == receipt.files.count else { throw IFDictionaryUpdateError(.verify, "prepared-extra-files") }
        guard try validatedManifest(at: directory.appendingPathComponent("shared")).contentVersion == version.contentVersion else {
            throw IFDictionaryUpdateError(.verify, "manifest-version")
        }
    }
}
