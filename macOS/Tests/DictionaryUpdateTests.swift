import Foundation

private func check(_ value: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if !value { fatalError(message, file: (file), line: line) }
}
private func fails(_ code: String? = nil, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected failure \(code ?? "")") }
    catch let error as IFDictionaryUpdateError { if let code { check(error.code == code, "Expected \(code), got \(error.technicalDetails)") } }
    catch { check(code == nil, "Unexpected error \(error)") }
}
private func asyncFails(_ code: String? = nil, _ body: () async throws -> Void) async {
    do { try await body(); fatalError("Expected failure \(code ?? "")") }
    catch let error as IFDictionaryUpdateError { if let code { check(error.code == code, "Expected \(code), got \(error.technicalDetails)") } }
    catch { check(code == nil, "Unexpected error \(error)") }
}
private let fakeCommit = String(repeating: "a", count: 40)
private let fakeTree = String(repeating: "b", count: 40)

private func network(_ mutation: String = "", changed: Bool = false) -> IFDictionarySourceClient {
    IFDictionarySourceClient(transport: { request, _ in
        let url = request.url!
        check(request.value(forHTTPHeaderField: "Authorization") == nil && !request.httpShouldHandleCookies, "No auth/cookies")
        check(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10", "Pinned API version")
        if mutation == "malformed" { return .init(url: url, status: 200, data: Data("{".utf8), expectedLength: 1) }
        if mutation == "offline" { throw URLError(.notConnectedToInternet) }
        if mutation == "timeout" { throw URLError(.timedOut) }
        if mutation == "403" || mutation == "429" { return .init(url: url, status: Int(mutation)!, data: Data([0]), expectedLength: 1) }
        if mutation == "redirect" { return .init(url: URL(string: "https://evil.example/dict")!, status: 200, data: Data([0]), expectedLength: 1) }
        let data: Data
        if url.path.contains("/commits/") {
            data = try JSONSerialization.data(withJSONObject: ["sha": mutation == "badcommit" ? "../head" : fakeCommit,
                "commit": ["tree": ["sha": fakeTree]]])
        } else if url.path.contains("/git/trees/") {
            let repository = IFDictionaryCatalog.sources.first { url.path.hasPrefix("/repos/\($0.repository)/") }!.repository
            let specs = IFDictionaryCatalog.sources.filter { $0.repository == repository }
            var entries = specs.map { spec -> [String: Any] in
                ["path": spec.path, "mode": mutation == "symlink" ? "120000" : "100644", "type": "blob",
                 "sha": changed && spec.id == "frost-8105" ? String(repeating: "c", count: 40) : spec.pinnedBlobSHA, "size": spec.pinnedByteCount]
            }
            if mutation == "missing" { entries.removeLast() }
            data = try JSONSerialization.data(withJSONObject: ["sha": fakeTree, "truncated": mutation == "truncated", "tree": entries])
        } else { fatalError("Check must never download raw data") }
        return .init(url: url, status: 200, data: data, expectedLength: Int64(data.count))
    })
}

@main struct DictionaryUpdateTests {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = URL(fileURLWithPath: arguments[2])
        let runtime = IFDictionaryRuntime.bundled(helper: repository.appendingPathComponent("build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker"))
        let fingerprint = try runtime.fingerprint()
        try await networkTests(repository)
        try storeTests(root: root, runtime: runtime, fingerprint: fingerprint)
        try cleanupTests(root: root, fingerprint: fingerprint)
        try await runnerFailures(root: root, runtime: runtime, repository: repository, fingerprint: fingerprint)
        try workerSuccess(root: root, runtime: runtime, repository: repository, fingerprint: fingerprint)
        try workerNativeFailures(root: root, runtime: runtime)
        print("PASS dictionary updates: all focused backend tests")
    }
    static func networkTests(_ repository: URL) async throws {
        let baseline = IFDictionaryCatalog.sources.map(\.pinnedReceipt)
        check(try await !network().check(observed: baseline).hasUpdate, "Unrelated commit must not offer update")
        check(try await network(changed: true).check(observed: baseline).hasUpdate, "Selected changed blob offers update")
        for (mutation, code) in [("missing", "tree-file"), ("truncated", "tree-incomplete"), ("symlink", "tree-file"),
                                 ("badcommit", "commit-format"), ("403", "http-status"), ("429", "http-status"),
                                 ("redirect", "redirect-host"), ("offline", "underlying"), ("timeout", "underlying")] {
            await asyncFails(code) { _ = try await network(mutation).check(observed: baseline) }
        }
        do { _ = try await network("malformed").check(observed: baseline); fatalError("Expected malformed response") }
        catch let error as IFDictionaryUpdateError {
            let firstRepository = IFDictionaryCatalog.sources.filter(\.isUpdatable).map(\.repository).sorted().first!
            check(error.code == "response-json" && error.source == firstRepository && error.file == "commit", "Malformed JSON retains endpoint/source context")
        }
        let specs = IFDictionaryCatalog.sources.filter(\.isUpdatable)
        let bytes = try Dictionary(uniqueKeysWithValues: specs.map { spec in
            (spec.id, try Data(contentsOf: repository.appendingPathComponent("build/dictionary-sources/\(spec.id).yaml")))
        })
        let checked = IFDictionaryCheck(sources: specs.map { .init(id: $0.id, commit: $0.pinnedCommit, blobSHA: $0.pinnedBlobSHA, byteCount: $0.pinnedByteCount) }, hasUpdate: true)
        let good = IFDictionarySourceClient(transport: { request, limit in
            let spec = specs.first { $0.rawURL(commit: $0.pinnedCommit) == request.url }!
            let data = bytes[spec.id]!
            check(data.count == limit, "Immutable checked byte limit")
            return .init(url: request.url!, status: 200, data: data, expectedLength: Int64(data.count))
        })
        let downloaded = try await good.download(checked)
        check(downloaded.count == specs.count && downloaded[0].receipt.sha256 == specs[0].pinnedSHA256, "Verified downloads")
        for corruption in ["truncate", "hash", "length", "oversize"] {
            let bad = IFDictionarySourceClient(transport: { request, _ in
                var data = bytes[specs[0].id]!
                if corruption == "truncate" { data.removeLast() }
                if corruption == "hash" { data[0] ^= 1 }
                if corruption == "oversize" { data.append(0) }
                return .init(url: request.url!, status: 200, data: data,
                    expectedLength: corruption == "length" ? Int64(data.count + 1) : Int64(data.count))
            })
            await asyncFails { _ = try await bad.download(checked) }
        }
        check(!IFDictionarySourceClient.isAllowed(URL(string: "http://api.github.com/")!), "HTTPS only")
        check(!IFDictionarySourceClient.isAllowed(URL(string: "https://user@api.github.com/")!), "No credential URL")
        let cancelled = Task { try await good.download(checked) }; cancelled.cancel()
        await asyncFails { _ = try await cancelled.value }
        print("PASS client: immutable no/change/unrelated checks; missing/tree/mode/status/redirect/offline/timeout/length/hash/cancellation")
    }
    static func fixture(store: IFDictionaryStore, runtime: IFDictionaryRuntime, fingerprint: String, versionCharacter: String) throws -> IFDictionaryVersion {
        let candidate = try store.candidate()
        let dictionary = Data("---\nname: pinyin_simp\n...\n你好\tni hao\t1\n".utf8)
        let original = try store.bundled(runtime.resources).manifest
        let manifest = IFDictionaryManifest(formatVersion: 1, recipeVersion: IFDictionaryCatalog.recipeVersion, contentVersion: "r\(IFDictionaryCatalog.recipeVersion)-" + String(repeating: versionCharacter, count: 64),
            entryCount: 1, contentSHA256: IFDictionaryHash.sha256(dictionary), dictionarySHA256: IFDictionaryHash.sha256(dictionary),
            correctionsSHA256: original.correctionsSHA256, sources: original.sources, calibrations: [])
        let shared = candidate.appendingPathComponent("shared"), cache = candidate.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        try dictionary.write(to: shared.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
        try manifest.encoded().write(to: shared.appendingPathComponent(IFDictionaryManifest.filename))
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
    static func storeTests(root: URL, runtime: IFDictionaryRuntime, fingerprint: String) throws {
        let store = try IFDictionaryStore(root: root.appendingPathComponent("store"))
        let first = try fixture(store: store, runtime: runtime, fingerprint: fingerprint, versionCharacter: "1")
        let second = try fixture(store: store, runtime: runtime, fingerprint: fingerprint, versionCharacter: "2")
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
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: runtime.resources)
        fails("symlink-path") { _ = try IFDictionaryFiles.child("symlink/pinyin_simp.dict.yaml", in: root) }
        fails("unsafe-candidate") { try store.removeCandidate(root) }
        let manifest = try store.resolve(first, fingerprint: fingerprint).manifest
        try store.recordContentUnchanged(manifest, activeContentVersion: manifest.contentVersion)
        check(try store.observed(active: manifest) == manifest.sources, "Bound observations")
        fails("observation-content") { try store.recordContentUnchanged(manifest, activeContentVersion: second.contentVersion) }
        let secondManifest = try store.resolve(second, fingerprint: fingerprint).manifest
        check(try store.observed(active: secondManifest) == secondManifest.sources, "Observations do not cross content versions")
        try store.confirmBundled(try store.bundled(runtime.resources).manifest, now: Date(timeIntervalSince1970: 400))
        check(try store.state().current == nil && store.state().bundled?.activatedAt == Date(timeIntervalSince1970: 400), "Bundled fallback metadata")
        let stateJSON = try String(contentsOf: store.root.appendingPathComponent("state.json"), encoding: .utf8)
        for key in ["error", "stderr", "detail", "diagnostic", "httpStatus"] { check(!stateJSON.contains(key), "No diagnostic persistence") }
        let cache = try store.resolve(second, fingerprint: fingerprint).cache!
        try Data("corrupt".utf8).write(to: cache.appendingPathComponent("pinyin_simp.table.bin"))
        fails("prepared-checksum") { _ = try store.resolve(second, fingerprint: fingerprint) }
        let fingerprintRoot = root.appendingPathComponent("runtime")
        try FileManager.default.copyItem(at: runtime.resources, to: fingerprintRoot)
        let changedRuntime = IFDictionaryRuntime(resources: fingerprintRoot, helper: runtime.helper, libraries: runtime.libraries)
        let before = try changedRuntime.fingerprint()
        try Data("different dictionary".utf8).write(to: fingerprintRoot.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
        check(try changedRuntime.fingerprint() == before, "Chinese content separate from runtime fingerprint")
        try Data("changed corrections".utf8).write(to: fingerprintRoot.appendingPathComponent(IFDictionaryCatalog.correctionsFilename))
        check(try changedRuntime.fingerprint() != before, "Corrections invalidate runtime")
        let replacement = try fixture(store: store, runtime: runtime, fingerprint: fingerprint, versionCharacter: "2")
        check(replacement.directory != second.directory, "Fresh artifact cannot collide with corrupt same-content cache")
        _ = try store.resolve(replacement, fingerprint: fingerprint)
        print("PASS store: begin/confirm/failure/interruption/fallback, same-content observations, safe paths, cache/fingerprint integrity, diagnostic-free atomic state")
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
    static func runnerFailures(root: URL, runtime: IFDictionaryRuntime, repository: URL, fingerprint: String) async throws {
        let user = root.appendingPathComponent("protected")
        let store = try IFDictionaryStore(root: user.appendingPathComponent("updates"))
        try Data("private sentinel".utf8).write(to: store.root.appendingPathComponent("blocked.txt"))
        let fixtureRuntime = IFDictionaryRuntime(resources: runtime.resources, helper: repository.appendingPathComponent("build/dictionary-worker-fixture"), libraries: [])
        let runner = IFDictionaryWorkerRunner(runtime: fixtureRuntime, protectedUserRoot: user, candidatesRoot: store.root.appendingPathComponent("candidates"), timeout: 10)
        for mode in ["stderr", "typed", "timeout", "sandbox"] {
            let candidate = try store.candidate()
            let request = IFDictionaryWorkerRequest(candidate: candidate, runtimeFingerprint: fingerprint, receipts: [], reuseDictionary: false,
                existing: .init(contentVersion: mode, runtimeFingerprint: fingerprint))
            let start = Date()
            var fixtureRunner = runner; if mode == "timeout" { fixtureRunner.timeout = 2 }
            do { _ = try fixtureRunner.runBlocking(request); fatalError("Expected fixture failure") }
            catch let error as IFDictionaryUpdateError {
                if mode == "stderr" { check(error.exitStatus == 17 && error.stderr!.contains("truncated") && error.stderr!.count < 16500, "Bounded draining stderr: \(error.technicalDetails.prefix(300)) count=\(error.stderr?.count ?? 0)") }
                if mode == "typed" { check(error.code == "fixture-compile" && error.stage == .prepare, "Typed prepare detail") }
                if mode == "timeout" { check(error.code == "worker-timeout" && error.stage == .verify && Date().timeIntervalSince(start) < 5, "Timeout kills resistant helper") }
                if mode == "sandbox" {
                    check(error.exitStatus == 23, "Sandbox denied protected read")
                    check(FileManager.default.fileExists(atPath: candidate.appendingPathComponent("allowed.txt").path), "Sandbox allows candidate writes")
                }
            }
            try store.removeCandidate(candidate)
        }
        fails("unsafe-candidate") {
            _ = try runner.runBlocking(.init(candidate: user.appendingPathComponent("pinyin_simp.userdb"), runtimeFingerprint: fingerprint,
                receipts: [], reuseDictionary: false, existing: nil))
        }
        let candidate = try store.candidate(), cancellation = IFDictionaryCancellation()
        cancellation.cancel()
        fails("cancelled") { _ = try runner.runBlocking(.init(candidate: candidate, runtimeFingerprint: fingerprint, receipts: [], reuseDictionary: false, existing: nil), cancellation: cancellation) }
        let runningCancellation = IFDictionaryCancellation()
        let request = IFDictionaryWorkerRequest(candidate: candidate, runtimeFingerprint: fingerprint, receipts: [], reuseDictionary: false,
            existing: .init(contentVersion: "timeout", runtimeFingerprint: fingerprint))
        var longRunner = runner; longRunner.timeout = 60
        let cancellableRunner = longRunner
        let task = Task.detached { try cancellableRunner.runBlocking(request, cancellation: runningCancellation) }
        try await Task.sleep(for: .milliseconds(150)); runningCancellation.cancel()
        await asyncFails("cancelled") { _ = try await task.value }
        print("PASS runner: sandbox protected read/candidate write, concurrent bounded stderr, prepare detail, verify timeout, cancellation cleanup")
    }
    static func workerSuccess(root: URL, runtime: IFDictionaryRuntime, repository: URL, fingerprint: String) throws {
        let user = root.appendingPathComponent("real-worker")
        let store = try IFDictionaryStore(root: user.appendingPathComponent("updates"))
        let runner = IFDictionaryWorkerRunner(runtime: runtime, protectedUserRoot: user, candidatesRoot: store.root.appendingPathComponent("candidates"))
        let specs = IFDictionaryCatalog.sources.filter(\.isUpdatable)
        var inputs = try specs.map { spec in
            IFDictionaryInput(receipt: spec.pinnedReceipt, data: try Data(contentsOf: repository.appendingPathComponent("build/dictionary-sources/\(spec.id).yaml")))
        }
        let candidate = try store.candidate()
        let prepared = try runner.prepareBlocking(candidate: candidate, inputs: inputs)
        check(prepared.outcome == .prepared, "Real generated resources compile and smoke")
        let version = try store.adopt(candidate, fingerprint: fingerprint)
        let descriptor = try store.resolve(version, fingerprint: fingerprint)
        check(descriptor.manifest.entryCount == IFDictionaryCatalog.initialEntryCount, "Full union entry count")
        check(FileManager.default.fileExists(atPath: descriptor.sharedData.deletingLastPathComponent().appendingPathComponent("raw/frost-8105.dict.yaml").path), "Retain verified inert sources for offline correction changes")
        try store.beginActivation(version)
        try store.confirmActivation(version)
        check(try store.state().current?.artifactID == version.artifactID, "Default fractional dates round trip through activation")
        // Updated immutable source with only a comment change must not activate or advance its timestamp.
        var bytes = inputs[0].data; bytes.insert(contentsOf: Data("# same content fixture\n".utf8), at: 0)
        inputs[0] = .init(receipt: .init(id: specs[0].id, commit: fakeCommit, blobSHA: IFDictionaryHash.gitBlob(bytes),
            sha256: IFDictionaryHash.sha256(bytes), byteCount: bytes.count, recordCount: 0), data: bytes)
        let identicalCandidate = try store.candidate()
        let identical = try runner.prepareBlocking(candidate: identicalCandidate, inputs: inputs,
            existing: .init(contentVersion: descriptor.manifest.contentVersion, runtimeFingerprint: fingerprint))
        check(identical.outcome == .contentUnchanged, "Comment-only source update short circuits compilation")
        try store.recordContentUnchanged(identical.manifest, activeContentVersion: descriptor.manifest.contentVersion)
        check(try store.observed(active: descriptor.manifest)[0].commit == fakeCommit, "Save proven same-content source receipts")
        check(!FileManager.default.fileExists(atPath: identicalCandidate.appendingPathComponent("cache").path), "No compile for same content")
        try store.removeCandidate(identicalCandidate)
        let malformed = try store.candidate()
        var bad = inputs
        let badBytes = Data("not a dictionary\n".utf8)
        bad[0] = .init(receipt: .init(id: specs[0].id, commit: fakeCommit, blobSHA: IFDictionaryHash.gitBlob(badBytes), sha256: IFDictionaryHash.sha256(badBytes), byteCount: badBytes.count, recordCount: 0), data: badBytes)
        fails("source-format") { _ = try runner.prepareBlocking(candidate: malformed, inputs: bad) }
        try store.removeCandidate(malformed)
        print("PASS real helper: full generated dictionary compile, clean first-choice/mixed/English/emoji smoke, same-content no-activation, malformed source rejection")
    }
    static func workerNativeFailures(root: URL, runtime: IFDictionaryRuntime) throws {
        let user = root.appendingPathComponent("native-failures")
        let store = try IFDictionaryStore(root: user.appendingPathComponent("updates"))
        let brokenBundle = root.appendingPathComponent("BrokenFixture.app")
        try FileManager.default.copyItem(at: runtime.helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), to: brokenBundle)
        let brokenRuntime = IFDictionaryRuntime.bundled(helper: brokenBundle.appendingPathComponent("Contents/MacOS/InkFlowDictionaryWorker"))
        try Data("schema: [\n".utf8).write(to: brokenRuntime.resources.appendingPathComponent("inkflow_pinyin.schema.yaml"))
        let brokenRunner = IFDictionaryWorkerRunner(runtime: brokenRuntime, protectedUserRoot: user, candidatesRoot: store.root.appendingPathComponent("candidates"))
        let brokenCandidate = try store.candidate()
        do { _ = try brokenRunner.rebuildBlocking(candidate: brokenCandidate, dictionaryShared: runtime.resources); fatalError("Expected native compile failure") }
        catch let error as IFDictionaryUpdateError {
            check(error.stage == .prepare && error.code == "rime-compile" && !(error.stderr ?? "").isEmpty,
                  "Native deployment notification failure: \(error.technicalDetails.prefix(500))")
        }
        try store.removeCandidate(brokenCandidate)
        let thinShared = root.appendingPathComponent("thin-dictionary")
        try FileManager.default.createDirectory(at: thinShared, withIntermediateDirectories: false)
        let data = Data("---\nname: pinyin_simp\nversion: 'fixture'\nsort: by_weight\nuse_preset_vocabulary: false\n...\n你好\tni hao\t100\n".utf8)
        let original = try store.bundled(runtime.resources).manifest
        let manifest = IFDictionaryManifest(formatVersion: 1, recipeVersion: IFDictionaryCatalog.recipeVersion, contentVersion: "r\(IFDictionaryCatalog.recipeVersion)-" + String(repeating: "3", count: 64),
            entryCount: 1, contentSHA256: IFDictionaryHash.sha256(data), dictionarySHA256: IFDictionaryHash.sha256(data),
            correctionsSHA256: original.correctionsSHA256, sources: original.sources, calibrations: [])
        try data.write(to: thinShared.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
        try manifest.encoded().write(to: thinShared.appendingPathComponent(IFDictionaryManifest.filename))
        let runner = IFDictionaryWorkerRunner(runtime: runtime, protectedUserRoot: user, candidatesRoot: store.root.appendingPathComponent("candidates"))
        let probeCandidate = try store.candidate()
        do { _ = try runner.rebuildBlocking(candidate: probeCandidate, dictionaryShared: thinShared); fatalError("Expected clean smoke failure") }
        catch let error as IFDictionaryUpdateError {
            check(error.stage == .verify && error.code == "smoke-probe", "Native probe failure stage: \(error.technicalDetails.prefix(500))")
        }
        try store.removeCandidate(probeCandidate)
        print("PASS native worker failures: invalid app-owned schema reports prepare/compile; valid incomplete dictionary reports verify/probe")
    }

}
