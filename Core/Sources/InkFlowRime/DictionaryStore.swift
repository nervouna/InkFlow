import InkFlowDomain
import Foundation
import CryptoKit
import Darwin

/// All paths originate locally; no source-supplied path is ever joined to a filesystem root.
package enum IFDictionaryFiles {
    /// Foundation collapses /private aliases differently before and after creation; use filesystem identity instead.
    package static func canonical(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
    package static func child(_ relative: String, in root: URL) throws -> URL {
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
    package static func hashes(in root: URL, excluding: Set<String> = [], didHashFile: @Sendable (URL) -> Void = { _ in }) throws -> [String: String] {
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
                result[relative] = try hash(file, didHashFile: didHashFile)
            }
        }
        return result
    }
    package static func hash(_ url: URL, didHashFile: @Sendable (URL) -> Void = { _ in }) throws -> String {
        guard try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw IFDictionaryUpdateError(.verify, "nonregular-file") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        // One reused buffer: FileHandle chunks are autoreleased and would all stay resident until the caller's pool drains.
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(file.fileDescriptor, $0.baseAddress, $0.count) }
            guard count != 0 else { break }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        didHashFile(url)
        return digest
    }
    package static func atomicWrite(_ data: Data, to url: URL) throws {
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
    package static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    package static func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
}

package struct IFDictionaryRuntime: Sendable {
    package let resources: URL
    package let helper: URL
    package let libraries: [URL]
    package func fingerprint() throws -> String {
        var files = try IFDictionaryFiles.hashes(in: resources, excluding: [IFDictionaryCatalog.dictionaryFilename,
            IFDictionaryManifest.filename, IFDictionaryCatalog.legacyFilename])
        files["@helper"] = try IFDictionaryFiles.hash(helper)
        for (offset, library) in libraries.enumerated() { files["@library/\(offset)/\(library.lastPathComponent)"] = try IFDictionaryFiles.hash(library) }
        return IFDictionaryHash.sha256(try IFDictionaryFiles.encode(files))
    }
    package init(resources: URL,
        helper: URL,
        libraries: [URL]) {
        self.resources = resources
        self.helper = helper
        self.libraries = libraries
    }

}
package struct IFDictionaryVersion: Codable, Equatable, Sendable {
    package let contentVersion: String
    package let runtimeFingerprint: String
    package let artifactID: String
    package let preparedAt: Date
    package var activatedAt: Date?
package init(contentVersion: String, runtimeFingerprint: String, preparedAt: Date, activatedAt: Date? = nil,
         artifactID: String = UUID().uuidString.lowercased()) {
        self.contentVersion = contentVersion; self.runtimeFingerprint = runtimeFingerprint; self.preparedAt = preparedAt
        self.activatedAt = activatedAt; self.artifactID = artifactID
    }
    package var directory: String { "versions/\(contentVersion)-\(runtimeFingerprint)-\(artifactID)" }
    /// Recipes advance consecutively from 1; accept only canonical generations this app knows.
    package static func recognizesRecipe(_ prefix: String) -> Bool {
        guard prefix.first == "r", let recipe = Int(prefix.dropFirst()),
              recipe >= 1, recipe <= IFDictionaryCatalog.recipeVersion else { return false }
        return prefix == "r\(recipe)"
    }
    package func validate() throws {
        // Keep historical journal identities readable so startup can reject incompatible
        // manifests and confirm the new bundled dictionary through normal recovery.
        let parts = contentVersion.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, Self.recognizesRecipe(String(parts[0])),
              IFDictionaryHash.isHex(String(parts[1]), length: 64),
              IFDictionaryHash.isHex(runtimeFingerprint, length: 64), UUID(uuidString: artifactID) != nil else { throw IFDictionaryUpdateError(.recovery, "invalid-version") }
    }
    package init(contentVersion: String,
        runtimeFingerprint: String,
        artifactID: String,
        preparedAt: Date,
        activatedAt: Date? = nil) {
        self.contentVersion = contentVersion
        self.runtimeFingerprint = runtimeFingerprint
        self.artifactID = artifactID
        self.preparedAt = preparedAt
        self.activatedAt = activatedAt
    }

}
package struct IFDictionaryBundledActivation: Codable, Equatable, Sendable {
    package let contentVersion: String
    package let activatedAt: Date
    package init(contentVersion: String,
        activatedAt: Date) {
        self.contentVersion = contentVersion
        self.activatedAt = activatedAt
    }

}
package struct IFDictionaryState: Codable, Equatable, Sendable {
    package var formatVersion = 1
    package var current: IFDictionaryVersion?
    package var previous: IFDictionaryVersion?
    package var pending: IFDictionaryVersion?
    package var transaction: IFDictionaryStage?
    package var bundled: IFDictionaryBundledActivation?
    package init(formatVersion: Int = 1,
        current: IFDictionaryVersion? = nil,
        previous: IFDictionaryVersion? = nil,
        pending: IFDictionaryVersion? = nil,
        transaction: IFDictionaryStage? = nil,
        bundled: IFDictionaryBundledActivation? = nil) {
        self.formatVersion = formatVersion
        self.current = current
        self.previous = previous
        self.pending = pending
        self.transaction = transaction
        self.bundled = bundled
    }

}
package struct IFDictionaryPreparedReceipt: Codable, Sendable {
    package static let filename = "prepared.json"
    package let contentVersion: String
    package let runtimeFingerprint: String
    package let files: [String: String]
    package init(contentVersion: String,
        runtimeFingerprint: String,
        files: [String: String]) {
        self.contentVersion = contentVersion
        self.runtimeFingerprint = runtimeFingerprint
        self.files = files
    }

}
package struct IFDictionaryDescriptor: Sendable {
    package let version: IFDictionaryVersion?
    package let manifest: IFDictionaryManifest
    package let sharedData: URL
    package let cache: URL?
    package init(version: IFDictionaryVersion?,
        manifest: IFDictionaryManifest,
        sharedData: URL,
        cache: URL?) {
        self.version = version
        self.manifest = manifest
        self.sharedData = sharedData
        self.cache = cache
    }

}

/// The update coordinator serializes mutations. Atomic state always keeps the last confirmed pointer.
package struct IFDictionaryStore: Sendable {
    package let root: URL
    package var beforeStateWrite: @Sendable (IFDictionaryState) throws -> Void = { _ in }
    /// Observes completed file hashing without replacing filesystem reads or validation.
    package var didHashFile: @Sendable (URL) -> Void = { _ in }
    package init(root: URL, beforeStateWrite: @escaping @Sendable (IFDictionaryState) throws -> Void = { _ in }) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = try IFDictionaryFiles.canonical(root); self.beforeStateWrite = beforeStateWrite
        for name in ["versions", "candidates"] {
            try FileManager.default.createDirectory(at: IFDictionaryFiles.child(name, in: self.root), withIntermediateDirectories: true)
        }
    }
    package func state() throws -> IFDictionaryState {
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
    package func candidate() throws -> URL {
        let url = try IFDictionaryFiles.child("candidates/\(UUID().uuidString.lowercased())", in: root)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    package func removeCandidate(_ url: URL) throws {
        guard url.deletingLastPathComponent().path == root.appendingPathComponent("candidates").path, UUID(uuidString: url.lastPathComponent) != nil,
              url.path == (try IFDictionaryFiles.canonical(url)).path else { throw IFDictionaryUpdateError(.prepare, "unsafe-candidate") }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private struct Observation: Codable { let contentVersion: String; let receipts: [IFDictionarySourceReceipt] }
    /// Save only after generation proves the sources produce the currently active content.
    package func recordContentUnchanged(_ manifest: IFDictionaryManifest, activeContentVersion: String) throws {
        guard manifest.contentVersion == activeContentVersion, manifest.sources.map(\.id) == IFDictionaryCatalog.sources.map(\.id) else {
            throw IFDictionaryUpdateError(.check, "observation-content")
        }
        try IFDictionaryFiles.atomicWrite(IFDictionaryFiles.encode(Observation(contentVersion: activeContentVersion, receipts: manifest.sources)),
                                          to: IFDictionaryFiles.child("observed.json", in: root))
    }
    package func observed(active: IFDictionaryManifest) throws -> [IFDictionarySourceReceipt] {
        let url = try IFDictionaryFiles.child("observed.json", in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return active.sources }
        let observation = try IFDictionaryFiles.decode(Observation.self, at: url)
        guard observation.contentVersion == active.contentVersion else { return active.sources }
        guard observation.receipts.map(\.id) == IFDictionaryCatalog.sources.map(\.id) else { throw IFDictionaryUpdateError(.check, "source-set") }
        return observation.receipts
    }
    package func adopt(_ candidate: URL, fingerprint: String, now: Date = Date()) throws -> IFDictionaryVersion {
        guard candidate.deletingLastPathComponent().path == root.appendingPathComponent("candidates").path, UUID(uuidString: candidate.lastPathComponent) != nil,
              candidate.path == (try IFDictionaryFiles.canonical(candidate)).path else { throw IFDictionaryUpdateError(.prepare, "unsafe-candidate") }
        let manifest = try validatedManifest(at: candidate.appendingPathComponent("shared"))
        let version = IFDictionaryVersion(contentVersion: manifest.contentVersion, runtimeFingerprint: fingerprint, preparedAt: now)
        try version.validate(); _ = try validatePrepared(at: candidate, version: version)
        let destination = try IFDictionaryFiles.child(version.directory, in: root)
        try FileManager.default.moveItem(at: candidate, to: destination)
        return version
    }
    package func resolve(_ version: IFDictionaryVersion, fingerprint: String) throws -> IFDictionaryDescriptor {
        try version.validate()
        guard version.runtimeFingerprint == fingerprint else { throw IFDictionaryUpdateError(.prepare, "runtime-changed") }
        let directory = try IFDictionaryFiles.child(version.directory, in: root)
        let manifest = try validatePrepared(at: directory, version: version)
        return .init(version: version, manifest: manifest,
                     sharedData: directory.appendingPathComponent("shared"), cache: directory.appendingPathComponent("cache"))
    }
    /// Inert source data for rebuilding with CURRENT app-owned schemas, Lua and correction policy.
    package func storedDictionary(_ version: IFDictionaryVersion) throws -> URL {
        try version.validate()
        let directory = try IFDictionaryFiles.child(version.directory + "/shared", in: root)
        let manifest = try validatedManifest(at: directory)
        guard manifest.contentVersion == version.contentVersion else { throw IFDictionaryUpdateError(.recovery, "manifest-version") }
        return directory
    }
    package func bundled(_ resources: URL) throws -> IFDictionaryDescriptor {
        .init(version: nil, manifest: try validatedManifest(at: resources), sharedData: resources, cache: nil)
    }
    package func beginActivation(_ version: IFDictionaryVersion) throws {
        _ = try resolve(version, fingerprint: version.runtimeFingerprint)
        try beginValidatedActivation(version)
    }
    /// Caller already resolved the immutable artifact in this serialized operation. Compact journal write only.
    package func beginValidatedActivation(_ version: IFDictionaryVersion) throws {
        try version.validate()
        var state = try state()
        guard state.pending == nil else { throw IFDictionaryUpdateError(.apply, "activation-in-progress") }
        state.pending = version; state.transaction = .apply; try save(state)
    }
    package func confirmActivation(_ version: IFDictionaryVersion, now: Date = Date()) throws {
        var state = try state()
        guard state.pending == version, state.transaction == .apply else { throw IFDictionaryUpdateError(.apply, "activation-mismatch") }
        var confirmed = version; confirmed.activatedAt = now
        state.previous = state.current; state.current = confirmed; state.bundled = nil; state.pending = nil; state.transaction = nil
        try save(state)
    }
    package func abandonActivation() throws {
        var state = try state(); state.pending = nil; state.transaction = nil; try save(state)
    }
    /// Never retries interrupted pending work. T3 selects fallback when confirmed cache is unavailable.
    package func recoverInterrupted() throws -> IFDictionaryState {
        var state = try state()
        if state.pending != nil { state.pending = nil; state.transaction = nil; try save(state) }
        return state
    }
    package func confirmFallback(_ version: IFDictionaryVersion) throws {
        _ = try resolve(version, fingerprint: version.runtimeFingerprint)
        try confirmValidatedFallback(version)
    }
    /// Caller has validated the artifact and successfully started its engine/sessions. No cache hashing here.
    package func confirmValidatedFallback(_ version: IFDictionaryVersion) throws {
        try version.validate()
        var state = try state(); state.current = version; state.bundled = nil; state.pending = nil; state.transaction = nil
        try save(state)
    }
    package func confirmBundled(_ manifest: IFDictionaryManifest, now: Date = Date()) throws {
        var state = try state(); state.current = nil; state.pending = nil; state.transaction = nil
        if state.bundled?.contentVersion != manifest.contentVersion {
            state.bundled = .init(contentVersion: manifest.contentVersion, activatedAt: now)
        }
        try save(state)
    }
    /// Repair an unreadable journal only after the bundled engine has actually started.
    package func repairBundled(_ manifest: IFDictionaryManifest, now: Date = Date()) throws {
        try Self.validateMetadata(manifest)
        var fresh = IFDictionaryState()
        fresh.bundled = .init(contentVersion: manifest.contentVersion, activatedAt: now)
        try save(fresh)
    }

    /// Bounded housekeeping within the owned store. Never visits the learning/custom-phrase root.
    /// Serialize with other store mutations and run off MainActor while input is served.
    @discardableResult
    package func cleanup(limit: Int = 32) throws -> Int {
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
                    let parts = entry.lastPathComponent.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                    valid = parts.count == 4 && IFDictionaryVersion.recognizesRecipe(parts[0]) &&
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

    package static func validateMetadata(_ manifest: IFDictionaryManifest) throws {
        try IFDictionaryVersion(contentVersion: manifest.contentVersion, runtimeFingerprint: String(repeating: "0", count: 64), preparedAt: .distantPast).validate()
        guard manifest.formatVersion == 1, manifest.recipeVersion == IFDictionaryCatalog.recipeVersion, manifest.entryCount > 0,
              manifest.contentVersion.hasPrefix("r\(manifest.recipeVersion)-"),
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
    package func validatedManifest(at shared: URL) throws -> IFDictionaryManifest {
        try validatedManifest(at: shared, dictionarySHA256: nil)
    }
    private func validatedManifest(at shared: URL, dictionarySHA256: String?) throws -> IFDictionaryManifest {
        let manifest = try IFDictionaryFiles.decode(IFDictionaryManifest.self, at: IFDictionaryFiles.child(IFDictionaryManifest.filename, in: shared))
        try Self.validateMetadata(manifest)
        let dictionarySHA256 = try dictionarySHA256 ?? IFDictionaryFiles.hash(
            IFDictionaryFiles.child(IFDictionaryCatalog.dictionaryFilename, in: shared), didHashFile: didHashFile)
        guard dictionarySHA256 == manifest.dictionarySHA256 else {
            throw IFDictionaryUpdateError(.verify, "manifest-integrity")
        }
        return manifest
    }
    private func validatePrepared(at directory: URL, version: IFDictionaryVersion) throws -> IFDictionaryManifest {
        let receipt = try IFDictionaryFiles.decode(IFDictionaryPreparedReceipt.self, at: IFDictionaryFiles.child(IFDictionaryPreparedReceipt.filename, in: directory))
        let required = ["shared/\(IFDictionaryManifest.filename)", "shared/\(IFDictionaryCatalog.dictionaryFilename)",
                        "shared/\(IFDictionaryCatalog.contextIndexFilename)",
                        "cache/inkflow_pinyin.schema.yaml", "cache/pinyin_simp.table.bin", "cache/pinyin_simp.prism.bin",
                        "cache/easy_en.table.bin", "cache/inkflow_mixed.table.bin"] +
                       InputPreferences.compiledSpellingFiles.map { "cache/\($0)" }
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
            guard IFDictionaryHash.isHex(hash, length: 64) else {
                throw IFDictionaryUpdateError(.verify, "prepared-checksum", file: path)
            }
            _ = try IFDictionaryFiles.child(path, in: directory)
        }
        var actual = [String: String]()
        for name in ["shared", "cache", "raw"] {
            let folder = try IFDictionaryFiles.child(name, in: directory)
            if FileManager.default.fileExists(atPath: folder.path) {
                for (path, hash) in try IFDictionaryFiles.hashes(in: folder, didHashFile: didHashFile) {
                    actual["\(name)/\(path)"] = hash
                }
            }
        }
        guard Set(actual.keys) == Set(receipt.files.keys) else { throw IFDictionaryUpdateError(.verify, "prepared-extra-files") }
        for (path, hash) in receipt.files where actual[path] != hash {
            throw IFDictionaryUpdateError(.verify, "prepared-checksum", file: path)
        }
        let manifest = try validatedManifest(at: directory.appendingPathComponent("shared"),
            dictionarySHA256: actual["shared/\(IFDictionaryCatalog.dictionaryFilename)"])
        guard manifest.contentVersion == version.contentVersion else {
            throw IFDictionaryUpdateError(.verify, "manifest-version")
        }
        return manifest
    }
}
