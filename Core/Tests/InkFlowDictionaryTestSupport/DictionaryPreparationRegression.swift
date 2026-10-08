import Foundation
@testable import InkFlowDomain
@testable import InkFlowRime

private func check(_ value: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if !value { fatalError(message, file: (file), line: line) }
}

private let fakeCommit = String(repeating: "a", count: 40)
private func asyncFails(_ code: String, _ body: () async throws -> Void) async {
    do { try await body(); fatalError("Expected failure \(code)") }
    catch let error as IFDictionaryUpdateError { check(error.code == code, "Expected \(code), got \(error.technicalDetails)") }
    catch { fatalError("Unexpected error \(error)") }
}

/// Shared assertions exercise real generation, compilation and clean probing through each host adapter.
package struct DictionaryPreparationRegression: Sendable {
    private let makeServices: @Sendable (IFDictionaryRuntime, URL, IFDictionaryStore) -> IFDictionaryServices
    private let copyRuntime: @Sendable (IFDictionaryRuntime, URL) throws -> IFDictionaryRuntime
    package init(makeServices: @escaping @Sendable (IFDictionaryRuntime, URL, IFDictionaryStore) -> IFDictionaryServices,
                 copyRuntime: @escaping @Sendable (IFDictionaryRuntime, URL) throws -> IFDictionaryRuntime) {
        self.makeServices = makeServices; self.copyRuntime = copyRuntime
    }
    package func run(root: URL, runtime: IFDictionaryRuntime, repository: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runtimeFingerprintTests(root: root, runtime: runtime)
        try await workerSuccess(root: root, runtime: runtime, repository: repository, fingerprint: runtime.fingerprint())
        try workerNativeFailures(root: root, runtime: runtime)
    }
    func runtimeFingerprintTests(root: URL, runtime: IFDictionaryRuntime) throws {
        let fingerprintRoot = root.appendingPathComponent("runtime")
        try FileManager.default.copyItem(at: runtime.resources, to: fingerprintRoot)
        let changedRuntime = IFDictionaryRuntime(resources: fingerprintRoot, helper: runtime.helper, libraries: runtime.libraries)
        let before = try changedRuntime.fingerprint()
        try Data("different dictionary".utf8).write(to: fingerprintRoot.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
        check(try changedRuntime.fingerprint() == before, "Chinese content separate from runtime fingerprint")
        try Data("changed corrections".utf8).write(to: fingerprintRoot.appendingPathComponent(IFDictionaryCatalog.correctionsFilename))
        check(try changedRuntime.fingerprint() != before, "Corrections invalidate runtime")
    }
    func workerSuccess(root: URL, runtime: IFDictionaryRuntime, repository: URL, fingerprint: String) async throws {
        let user = root.appendingPathComponent("real-worker")
        let store = try IFDictionaryStore(root: user.appendingPathComponent("updates"))
        let services = makeServices(runtime, user, store)
        let specs = IFDictionaryCatalog.sources.filter(\.isUpdatable)
        var inputs = try specs.map { spec in
            IFDictionaryInput(receipt: spec.pinnedReceipt, data: try Data(contentsOf: repository.appendingPathComponent("build/dictionary-sources/\(spec.id).yaml")))
        }
        let candidate = try store.candidate()
        let prepared = try await services.prepare(candidate, inputs, nil, { _ in })
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
        let identical = try await services.prepare(identicalCandidate, inputs,
            .init(contentVersion: descriptor.manifest.contentVersion, runtimeFingerprint: fingerprint), { _ in })
        check(identical.outcome == .contentUnchanged, "Comment-only source update short circuits compilation")
        try store.recordContentUnchanged(identical.manifest, activeContentVersion: descriptor.manifest.contentVersion)
        check(try store.observed(active: descriptor.manifest)[0].commit == fakeCommit, "Save proven same-content source receipts")
        check(!FileManager.default.fileExists(atPath: identicalCandidate.appendingPathComponent("cache").path), "No compile for same content")
        try store.removeCandidate(identicalCandidate)

        // A new legal syllable must update the guard in downloaded and dictionary-only
        // rebuilds, even though the app's bundled schema still has the old inventory.
        bytes.append(Data("\n新拼写\tboa\t1\n".utf8))
        inputs[0] = .init(receipt: .init(id: specs[0].id, commit: fakeCommit, blobSHA: IFDictionaryHash.gitBlob(bytes),
            sha256: IFDictionaryHash.sha256(bytes), byteCount: bytes.count, recordCount: 0), data: bytes)
        let expandedCandidate = try store.candidate()
        let expanded = try await services.prepare(expandedCandidate, inputs, nil, { _ in })
        check(expanded.outcome == .prepared, "A new source syllable compiles")
        let expandedShared = expandedCandidate.appendingPathComponent("shared")
        let expandedDictionary = try Data(contentsOf: expandedShared.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
        let expectedSchemas = try IFSpellingGenerator.generate(dictionary: expandedDictionary)
        for (name, data) in expectedSchemas {
            check(try Data(contentsOf: expandedShared.appendingPathComponent(name)) == data, "Download regenerates spelling schema: \(name)")
        }
        let expectedIndex = try IFContextRanker.buildIndex(dictionary: expandedDictionary)
        check(try Data(contentsOf: expandedShared.appendingPathComponent(IFDictionaryCatalog.contextIndexFilename)) == expectedIndex,
              "Download regenerates the context index")
        check(try Data(contentsOf: runtime.resources.appendingPathComponent("inkflow_spelling_2.schema.yaml")) != expectedSchemas["inkflow_spelling_2.schema.yaml"],
              "Downloaded guard differs from the bundled dictionary inventory")
        let reuse = root.appendingPathComponent("spelling-rebuild")
        try FileManager.default.createDirectory(at: reuse, withIntermediateDirectories: false)
        for name in [IFDictionaryCatalog.dictionaryFilename, IFDictionaryManifest.filename] {
            try FileManager.default.copyItem(at: expandedShared.appendingPathComponent(name), to: reuse.appendingPathComponent(name))
        }
        let rebuiltCandidate = try store.candidate()
        let rebuilt = try services.rebuild(rebuiltCandidate, reuse)
        check(rebuilt.outcome == .prepared, "Dictionary-only rebuild compiles with current spelling logic")
        for (name, data) in expectedSchemas {
            check(try Data(contentsOf: rebuiltCandidate.appendingPathComponent("shared/" + name)) == data,
                  "Dictionary-only rebuild regenerates spelling schema: \(name)")
        }
        check(try Data(contentsOf: rebuiltCandidate.appendingPathComponent("shared/" + IFDictionaryCatalog.contextIndexFilename)) == expectedIndex,
              "Dictionary-only rebuild regenerates the context index")
        try store.removeCandidate(expandedCandidate)
        try store.removeCandidate(rebuiltCandidate)
        let malformed = try store.candidate()
        var bad = inputs
        let badBytes = Data("not a dictionary\n".utf8)
        bad[0] = .init(receipt: .init(id: specs[0].id, commit: fakeCommit, blobSHA: IFDictionaryHash.gitBlob(badBytes), sha256: IFDictionaryHash.sha256(badBytes), byteCount: badBytes.count, recordCount: 0), data: badBytes)
        await asyncFails("source-format") { _ = try await services.prepare(malformed, bad, nil, { _ in }) }
        try store.removeCandidate(malformed)
        print("PASS real helper: full generated dictionary compile, clean first-choice/mixed/English/emoji smoke, same-content no-activation, malformed source rejection")
    }
    func workerNativeFailures(root: URL, runtime: IFDictionaryRuntime) throws {
        let user = root.appendingPathComponent("native-failures")
        let store = try IFDictionaryStore(root: user.appendingPathComponent("updates"))
        let brokenRuntime = try copyRuntime(runtime, root.appendingPathComponent("broken-runtime"))
        try Data("schema: [\n".utf8).write(to: brokenRuntime.resources.appendingPathComponent("inkflow_pinyin.schema.yaml"))
        let brokenServices = makeServices(brokenRuntime, user, store)
        let brokenCandidate = try store.candidate()
        do { _ = try brokenServices.rebuild(brokenCandidate, runtime.resources); fatalError("Expected native compile failure") }
        catch let error as IFDictionaryUpdateError {
            check(error.stage == .prepare && error.code == "rime-compile" && error.detail.hasPrefix("operation=compile;") && !(error.stderr ?? "").isEmpty,
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
        let services = makeServices(runtime, user, store)
        let probeCandidate = try store.candidate()
        do { _ = try services.rebuild(probeCandidate, thinShared); fatalError("Expected clean smoke failure") }
        catch let error as IFDictionaryUpdateError {
            check(error.stage == .verify && error.code == "smoke-probe" && error.detail.hasPrefix("operation=clean-smoke; probe="), "Native probe failure stage: \(error.technicalDetails.prefix(500))")
        }
        try store.removeCandidate(probeCandidate)
        print("PASS native worker failures: invalid app-owned schema reports prepare/compile; valid incomplete dictionary reports verify/probe")
    }

}
