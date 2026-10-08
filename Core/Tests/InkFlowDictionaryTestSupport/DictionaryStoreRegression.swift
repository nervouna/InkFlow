import Foundation
@testable import InkFlowDomain
@testable import InkFlowRime

private func check(_ value: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if !value { fatalError(message, file: (file), line: line) }
}
private func fails(_ code: String? = nil, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected failure \(code ?? "")") }
    catch let error as IFDictionaryUpdateError { if let code { check(error.code == code, "Expected \(code), got \(error.technicalDetails)") } }
    catch { check(code == nil, "Unexpected error \(error)") }
}
private final class FileHashCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    let root: URL
    init(root: URL) { self.root = root }
    func record(_ url: URL) {
        let prefix = root.path + "/"
        guard url.path.hasPrefix(prefix) else { return }
        let parts = url.path.dropFirst(prefix.count).split(separator: "/")
        guard parts.count > 2, parts[0] == "candidates" || parts[0] == "versions" else { return }
        let relative = parts.dropFirst(2).joined(separator: "/")
        lock.lock(); defer { lock.unlock() }
        counts[relative, default: 0] += 1
    }
    var snapshot: [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
}

package func verifyDictionaryStore(in root: URL) throws {
    try DictionaryStoreRegression.run(root: root)
}

private enum DictionaryStoreRegression {
    static func run(root: URL) throws {
        let resources = root.appendingPathComponent("synthetic-resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let dictionary = Data("---\nname: pinyin_simp\n...\n你好\tni hao\t1\n".utf8)
        let hash = IFDictionaryHash.sha256(dictionary)
        let manifest = IFDictionaryManifest(formatVersion: 1, recipeVersion: IFDictionaryCatalog.recipeVersion,
            contentVersion: "r\(IFDictionaryCatalog.recipeVersion)-" + hash, entryCount: 1,
            contentSHA256: hash, dictionarySHA256: hash, correctionsSHA256: hash,
            sources: IFDictionaryCatalog.sources.map { spec in var receipt = spec.pinnedReceipt; receipt.recordCount = 1; return receipt }, calibrations: [])
        try dictionary.write(to: resources.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
        try manifest.encoded().write(to: resources.appendingPathComponent(IFDictionaryManifest.filename))
        let fingerprint = String(repeating: "a", count: 64)
        try storeTests(root: root, resources: resources, fingerprint: fingerprint)
        try validationHashCounts(root: root, resources: resources, fingerprint: fingerprint)
        try validationFailures(root: root, resources: resources, fingerprint: fingerprint)
        try cleanupTests(root: root, fingerprint: fingerprint)
    }
    static func fixture(store: IFDictionaryStore, resources: URL, fingerprint: String, versionCharacter: String) throws -> IFDictionaryVersion {
        let candidate = try store.candidate()
        let dictionary = Data("---\nname: pinyin_simp\n...\n你好\tni hao\t1\n".utf8)
        let original = try store.bundled(resources).manifest
        let manifest = IFDictionaryManifest(formatVersion: 1, recipeVersion: IFDictionaryCatalog.recipeVersion, contentVersion: "r\(IFDictionaryCatalog.recipeVersion)-" + String(repeating: versionCharacter, count: 64),
            entryCount: 1, contentSHA256: IFDictionaryHash.sha256(dictionary), dictionarySHA256: IFDictionaryHash.sha256(dictionary),
            correctionsSHA256: original.correctionsSHA256, sources: original.sources, calibrations: [])
        let shared = candidate.appendingPathComponent("shared"), cache = candidate.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        try dictionary.write(to: shared.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
        try manifest.encoded().write(to: shared.appendingPathComponent(IFDictionaryManifest.filename))
        try IFContextRanker.buildIndex(dictionary: dictionary).write(to: shared.appendingPathComponent(IFDictionaryCatalog.contextIndexFilename))
        for name in ["inkflow_pinyin.schema.yaml", "pinyin_simp.table.bin", "pinyin_simp.prism.bin", "easy_en.table.bin", "inkflow_mixed.table.bin"] + InputPreferences.compiledSpellingFiles {
            try Data("compiled fixture".utf8).write(to: cache.appendingPathComponent(name))
        }
        var hashes = [String: String]()
        for (path, hash) in try IFDictionaryFiles.hashes(in: shared) { hashes["shared/\(path)"] = hash }
        for (path, hash) in try IFDictionaryFiles.hashes(in: cache) { hashes["cache/\(path)"] = hash }
        try IFDictionaryFiles.encode(IFDictionaryPreparedReceipt(contentVersion: manifest.contentVersion, runtimeFingerprint: fingerprint, files: hashes))
            .write(to: candidate.appendingPathComponent(IFDictionaryPreparedReceipt.filename))
        return try store.adopt(candidate, fingerprint: fingerprint, now: Date(timeIntervalSince1970: 100))
    }
    static func storeTests(root: URL, resources: URL, fingerprint: String) throws {
        let store = try IFDictionaryStore(root: root.appendingPathComponent("store"))
        let first = try fixture(store: store, resources: resources, fingerprint: fingerprint, versionCharacter: "1")
        let second = try fixture(store: store, resources: resources, fingerprint: fingerprint, versionCharacter: "2")
        var broken = store; broken.beforeStateWrite = { _ in throw CocoaError(.fileWriteNoPermission) }
        fails { try broken.beginActivation(first) }
        check(try store.state().current == nil && store.state().pending == nil, "Failed begin preserves empty state")
        try store.beginActivation(first)
        fails { try broken.confirmActivation(first) }
        check(try store.state().current == nil && store.state().pending == first, "Failed confirm preserves previous confirmed")
        try store.confirmActivation(first, now: Date(timeIntervalSince1970: 200))
        let confirmed = try store.state().current!
        try store.beginActivation(second)
        fails("activation-in-progress") { try store.beginActivation(first) }
        fails { try broken.abandonActivation() }
        check(try store.state().current == confirmed && store.state().pending == second, "Failed abandon retains confirmed")
        check(try store.recoverInterrupted().current == confirmed && store.state().pending == nil, "Interrupted activation never retries")
        try store.beginActivation(second); try store.confirmActivation(second, now: Date(timeIntervalSince1970: 300))
        check(try store.state().previous == confirmed, "Previous preserved")
        try store.confirmFallback(confirmed)
        check(try store.state().current == confirmed, "Rollback pointer recorded")
        fails("runtime-changed") { _ = try store.resolve(first, fingerprint: String(repeating: "f", count: 64)) }
        fails("unsafe-path") { _ = try IFDictionaryFiles.child("../outside", in: root) }
        let link = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: resources)
        fails("symlink-path") { _ = try IFDictionaryFiles.child("symlink/pinyin_simp.dict.yaml", in: root) }
        fails("unsafe-candidate") { try store.removeCandidate(root) }
        let manifest = try store.resolve(first, fingerprint: fingerprint).manifest
        try store.recordContentUnchanged(manifest, activeContentVersion: manifest.contentVersion)
        check(try store.observed(active: manifest) == manifest.sources, "Bound observations")
        fails("observation-content") { try store.recordContentUnchanged(manifest, activeContentVersion: second.contentVersion) }
        let secondManifest = try store.resolve(second, fingerprint: fingerprint).manifest
        check(try store.observed(active: secondManifest) == secondManifest.sources, "Observations do not cross content versions")
        try store.confirmBundled(try store.bundled(resources).manifest, now: Date(timeIntervalSince1970: 400))
        check(try store.state().current == nil && store.state().bundled?.activatedAt == Date(timeIntervalSince1970: 400), "Bundled fallback metadata")
        let stateJSON = try String(contentsOf: store.root.appendingPathComponent("state.json"), encoding: .utf8)
        for key in ["error", "stderr", "detail", "diagnostic", "httpStatus"] { check(!stateJSON.contains(key), "No diagnostic persistence") }
        let cache = try store.resolve(second, fingerprint: fingerprint).cache!
        try Data("corrupt".utf8).write(to: cache.appendingPathComponent("pinyin_simp.table.bin"))
        fails("prepared-checksum") { _ = try store.resolve(second, fingerprint: fingerprint) }
        let replacement = try fixture(store: store, resources: resources, fingerprint: fingerprint, versionCharacter: "2")
        check(replacement.directory != second.directory, "Fresh artifact cannot collide with corrupt same-content cache")
        _ = try store.resolve(replacement, fingerprint: fingerprint)
        print("PASS store: begin/confirm/failure/interruption/fallback, same-content observations, safe paths, cache/fingerprint integrity, diagnostic-free atomic state")
    }
    static func validationHashCounts(root: URL, resources: URL, fingerprint: String) throws {
        var store = try IFDictionaryStore(root: root.appendingPathComponent("hash-counts"))
        let counts = FileHashCounts(root: store.root)
        store.didHashFile = { counts.record($0) }
        let version = try fixture(store: store, resources: resources, fingerprint: fingerprint, versionCharacter: "3")
        _ = try store.resolve(version, fingerprint: fingerprint)
        try store.beginValidatedActivation(version)
        let receipt = try IFDictionaryFiles.decode(IFDictionaryPreparedReceipt.self,
            at: store.root.appendingPathComponent(version.directory).appendingPathComponent(IFDictionaryPreparedReceipt.filename))
        let observed = counts.snapshot
        let dictionaryPath = "shared/\(IFDictionaryCatalog.dictionaryFilename)"
        let summary = "HASH COUNTS adopt/resolve/journal: files=\(receipt.files.count), total=\(observed.values.reduce(0, +)), dictionary=\(observed[dictionaryPath, default: 0]), other=\(Set(observed.filter { $0.key != dictionaryPath }.map(\.value)).sorted())\n"
        try FileHandle.standardOutput.write(contentsOf: Data(summary.utf8))
        check(Set(observed.keys) == Set(receipt.files.keys), "Observe every prepared file")
        for path in receipt.files.keys {
            check(observed[path] == (path == dictionaryPath ? 3 : 2), "Two complete validations plus first-receipt dictionary integrity: \(path), observed \(observed[path, default: 0])")
        }
        try store.confirmActivation(version)
        check(counts.snapshot == observed, "Activation confirmation only writes the journal")
        _ = try store.resolve(version, fingerprint: fingerprint)
        for path in receipt.files.keys {
            check(counts.snapshot[path] == observed[path]! + 1, "Later resolve rehashes every file: \(path)")
        }
        print("PASS store hashing: adopt/resolve/journal performs two whole-set reads plus initial dictionary integrity")
    }
    static func validationFailures(root: URL, resources: URL, fingerprint: String) throws {
        let store = try IFDictionaryStore(root: root.appendingPathComponent("validation-failures"))
        let manager = FileManager.default
        let cachePath = "cache/pinyin_simp.table.bin"
        let dictionaryPath = "shared/\(IFDictionaryCatalog.dictionaryFilename)"
        let manifestPath = "shared/\(IFDictionaryManifest.filename)"
        let scenarios = [
            ("corrupt", "prepared-checksum"), ("missing", "prepared-extra-files"),
            ("extra-shared", "prepared-extra-files"), ("extra-cache", "prepared-extra-files"), ("extra-raw", "prepared-extra-files"),
            ("same-count-replacement", "prepared-extra-files"), ("missing-required-receipt", "prepared-file-missing"),
            ("invalid-hash", "prepared-checksum"), ("outside-prefix", "prepared-path"),
            ("parent-path", "unsafe-path"), ("empty-component", "unsafe-path"), ("dot-component", "unsafe-path"),
            ("backslash", "unsafe-path"), ("receipt-symlink", "symlink-path"), ("extra-symlink", "symlink-resource"),
            ("receipt-version", "prepared-version"), ("receipt-runtime", "prepared-version"),
            ("manifest-version", "manifest-version"), ("manifest-metadata", "manifest-metadata"),
            ("manifest-source", "manifest-source"), ("dictionary-and-receipt", "manifest-integrity")
        ]
        for (scenario, expected) in scenarios {
            let version = try fixture(store: store, resources: resources, fingerprint: fingerprint, versionCharacter: "4")
            let directory = store.root.appendingPathComponent(version.directory)
            let receiptURL = directory.appendingPathComponent(IFDictionaryPreparedReceipt.filename)
            let receipt = try IFDictionaryFiles.decode(IFDictionaryPreparedReceipt.self, at: receiptURL)
            var files = receipt.files, contentVersion = receipt.contentVersion, runtimeFingerprint = receipt.runtimeFingerprint
            switch scenario {
            case "corrupt": try Data("corrupt".utf8).write(to: directory.appendingPathComponent(cachePath))
            case "missing": try manager.removeItem(at: directory.appendingPathComponent(cachePath))
            case "extra-shared", "extra-cache", "extra-raw":
                let folder = directory.appendingPathComponent(String(scenario.dropFirst("extra-".count)))
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("extra".utf8).write(to: folder.appendingPathComponent("unexpected"))
            case "same-count-replacement":
                try manager.moveItem(at: directory.appendingPathComponent(cachePath), to: directory.appendingPathComponent("cache/substitute.bin"))
            case "missing-required-receipt": files.removeValue(forKey: cachePath)
            case "invalid-hash": files[cachePath] = "not-a-sha256"
            case "outside-prefix": files["outside/file"] = files[cachePath]
            case "parent-path": files["cache/../cache/pinyin_simp.table.bin"] = files[cachePath]
            case "empty-component": files["cache//pinyin_simp.table.bin"] = files[cachePath]
            case "dot-component": files["cache/./pinyin_simp.table.bin"] = files[cachePath]
            case "backslash": files["cache/unsafe\\file"] = files[cachePath]
            case "receipt-symlink":
                let file = directory.appendingPathComponent(cachePath)
                try manager.removeItem(at: file)
                try manager.createSymbolicLink(at: file, withDestinationURL: resources.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
            case "extra-symlink":
                try manager.createSymbolicLink(at: directory.appendingPathComponent("cache/unexpected"), withDestinationURL: resources)
            case "receipt-version": contentVersion = "r\(IFDictionaryCatalog.recipeVersion)-" + String(repeating: "5", count: 64)
            case "receipt-runtime": runtimeFingerprint = String(repeating: "b", count: 64)
            case "manifest-version", "manifest-metadata", "manifest-source":
                let url = directory.appendingPathComponent(manifestPath)
                var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                if scenario == "manifest-version" {
                    manifest["contentVersion"] = "r\(IFDictionaryCatalog.recipeVersion)-" + String(repeating: "5", count: 64)
                } else if scenario == "manifest-metadata" {
                    manifest["entryCount"] = 0
                } else {
                    var sources = manifest["sources"] as! [[String: Any]]
                    sources[0]["path"] = "unexpected-source.yaml"; manifest["sources"] = sources
                }
                try JSONSerialization.data(withJSONObject: manifest).write(to: url)
                files[manifestPath] = try IFDictionaryFiles.hash(url)
            case "dictionary-and-receipt":
                let url = directory.appendingPathComponent(dictionaryPath)
                try Data("changed dictionary with self-consistent receipt".utf8).write(to: url)
                files[dictionaryPath] = try IFDictionaryFiles.hash(url)
            default: fatalError("Unknown validation fixture: \(scenario)")
            }
            try IFDictionaryFiles.encode(IFDictionaryPreparedReceipt(contentVersion: contentVersion,
                runtimeFingerprint: runtimeFingerprint, files: files)).write(to: receiptURL)
            fails(expected) { _ = try store.resolve(version, fingerprint: fingerprint) }
            let reopened = try IFDictionaryStore(root: store.root)
            fails(expected) { _ = try reopened.resolve(version, fingerprint: fingerprint) }
            fails(expected) { try reopened.beginActivation(version) }
            check(try reopened.state().pending == nil, "Invalid artifact never reaches the activation journal: \(scenario)")
            let candidate = try store.candidate()
            for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try manager.copyItem(at: file, to: candidate.appendingPathComponent(file.lastPathComponent))
            }
            fails(scenario == "manifest-version" ? "prepared-version" : expected) {
                _ = try store.adopt(candidate, fingerprint: fingerprint)
            }
            check(manager.fileExists(atPath: candidate.path), "Invalid first receipt remains unadopted: \(scenario)")
            try store.removeCandidate(candidate)
        }
        print("PASS prepared validation: \(scenarios.count) corruption/path/symlink/metadata/version cases rejected on first receipt, existing and reopened stores before journaling")
    }
    static func cleanupTests(root: URL, fingerprint: String) throws {
        let user = root.appendingPathComponent("cleanup-user")
        let store = try IFDictionaryStore(root: user.appendingPathComponent("updates"))
        let manager = FileManager.default
        let sentinel = Data("preserve owned data and outside targets".utf8)
        func directory(_ relative: String) throws -> URL {
            let url = store.root.appendingPathComponent(relative)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try sentinel.write(to: url.appendingPathComponent("sentinel"))
            return url
        }
        func version(_ recipe: Int, _ character: String) -> IFDictionaryVersion {
            .init(contentVersion: "r\(recipe)-" + String(repeating: character, count: 64),
                  runtimeFingerprint: fingerprint, preparedAt: .distantPast)
        }

        // All three historical journal references remain protected even though their manifests are obsolete.
        let retained = [version(1, "1"), version(1, "2"), version(1, "3")]
        for item in retained { _ = try directory(item.directory) }
        let journal = try IFDictionaryFiles.encode(IFDictionaryState(current: retained[0], previous: retained[1],
                                                                     pending: retained[2], transaction: .apply))
        let journalURL = store.root.appendingPathComponent("state.json")
        try journal.write(to: journalURL)
        check(try store.state().pending == retained[2], "Historical references remain readable for cleanup")

        let abandoned = [version(1, "4"), version(1, "5"), version(IFDictionaryCatalog.recipeVersion, "6"),
                         version(IFDictionaryCatalog.recipeVersion, "7"), version(IFDictionaryCatalog.recipeVersion, "8")]
        var removable = try abandoned.map { try directory($0.directory) }
        for _ in 0..<3 { removable.append(try directory("candidates/" + UUID().uuidString.lowercased())) }

        let hash = String(repeating: "a", count: 64), uuid = UUID().uuidString.lowercased()
        let unsupported = ["r0", "r01", "r\(IFDictionaryCatalog.recipeVersion + 1)", "r9999999999999999999999999", "rx"]
        for prefix in unsupported {
            fails("invalid-version") {
                try IFDictionaryVersion(contentVersion: "\(prefix)-\(hash)", runtimeFingerprint: fingerprint,
                                        preparedAt: .distantPast).validate()
            }
        }
        var protected = try unsupported.map { try directory("versions/\($0)-\(hash)-\(fingerprint)-\(uuid)") }
        for name in ["r1--\(hash)-\(fingerprint)-\(uuid)", "r1-\(hash)--\(fingerprint)-\(uuid)",
                     "r1-\(hash)-\(fingerprint)-not-a-uuid", "r1-xyz-\(fingerprint)-\(uuid)",
                     "r\(IFDictionaryCatalog.recipeVersion)-\(hash)-xyz-\(uuid)", "user-notes"] {
            protected.append(try directory("versions/\(name)"))
        }
        protected.append(try directory("candidates/not-a-uuid"))
        protected += retained.map { store.root.appendingPathComponent($0.directory) }
        // A regular file with an otherwise owned identity must not be recursively removed either.
        let regularFile = store.root.appendingPathComponent(version(1, "9").directory)
        try sentinel.write(to: regularFile)

        let outside = root.appendingPathComponent("cleanup-outside")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideSentinel = outside.appendingPathComponent("sentinel")
        try sentinel.write(to: outsideSentinel)
        let symlinkNames = ["candidates/" + UUID().uuidString.lowercased(), version(1, "b").directory,
                            version(IFDictionaryCatalog.recipeVersion, "c").directory]
        let symlinks = symlinkNames.map { store.root.appendingPathComponent($0) }
        for link in symlinks { try manager.createSymbolicLink(at: link, withDestinationURL: outside) }

        let userdb = user.appendingPathComponent("pinyin_simp.userdb")
        try manager.createDirectory(at: userdb, withIntermediateDirectories: false)
        let dataFiles = [userdb.appendingPathComponent("learning"), user.appendingPathComponent("custom_phrase.txt"),
                         store.root.appendingPathComponent("observed.json")]
        for file in dataFiles { try sentinel.write(to: file) }

        check(try store.cleanup(limit: 0) == 0, "Zero cleanup budget leaves every artifact untouched")
        check(removable.allSatisfy { manager.fileExists(atPath: $0.path) }, "Zero budget does not delete artifacts")
        var total = 0
        for pass in 0..<4 {
            let removed = try store.cleanup(limit: 2)
            check(removed == 2, "Bounded cleanup pass \(pass) removes exactly two obsolete artifacts")
            total += removed
            check(removable.filter { manager.fileExists(atPath: $0.path) }.count == removable.count - total,
                  "Only the counted unreferenced artifacts disappear")
        }
        check(try total == removable.count && store.cleanup(limit: 2) == 0, "Repeated cleanup converges without accumulating historical artifacts")
        for folder in protected { check(try Data(contentsOf: folder.appendingPathComponent("sentinel")) == sentinel, "Retained or unknown directory preserved: \(folder.lastPathComponent)") }
        for link in symlinks {
            check(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true, "Valid-looking symlink is preserved")
        }
        for file in dataFiles + [outsideSentinel, regularFile] { check(try Data(contentsOf: file) == sentinel, "Cleanup preserves data outside removable owned directories") }
        check(try Data(contentsOf: journalURL) == journal, "Cleanup never rewrites retained journal references")
        print("PASS cleanup: retained r1 current/previous/pending, obsolete r1/current artifacts and candidates, unknown/malformed identities, symlinks/outside/user data, zero budget and bounded convergence")
    }
}
