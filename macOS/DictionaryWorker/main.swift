import Foundation
import Darwin

func emit(_ event: IFDictionaryWorkerEvent) throws {
    var data = try JSONEncoder().encode(event); data.append(0x0a)
    try FileHandle.standardOutput.write(contentsOf: data)
}

var stage = IFDictionaryStage.prepare
var operation = "request"
do {
    guard CommandLine.arguments.count == 2 else { throw IFDictionaryUpdateError(.prepare, "worker-arguments") }
    let requestURL = try IFDictionaryFiles.canonical(URL(fileURLWithPath: CommandLine.arguments[1]))
    let request = try IFDictionaryFiles.decode(IFDictionaryWorkerRequest.self, at: requestURL)
    let root = request.candidate
    guard root.path == (try IFDictionaryFiles.canonical(root)).path,
          requestURL.path == root.appendingPathComponent("request.json").path else { throw IFDictionaryUpdateError(.prepare, "unsafe-candidate") }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    operation = "runtime-fingerprint"
    let runtime = IFDictionaryRuntime.bundled(helper: executable)
    guard try runtime.fingerprint() == request.runtimeFingerprint else { throw IFDictionaryUpdateError(.prepare, "runtime-changed") }
    try emit(.init(progress: .init(stage: .prepare, completed: 0, total: 2)))
    operation = "generate-dictionary"
    let dictionary: Data
    let manifest: IFDictionaryManifest
    if request.reuseDictionary {
        guard request.receipts.isEmpty else { throw IFDictionaryUpdateError(.prepare, "source-set") }
        let reuse = try IFDictionaryFiles.child("rebuild", in: root)
        // A store instance is not needed here: validate the inert old dictionary against its manifest.
        manifest = try IFDictionaryFiles.decode(IFDictionaryManifest.self, at: IFDictionaryFiles.child(IFDictionaryManifest.filename, in: reuse))
        try IFDictionaryStore.validateMetadata(manifest)
        dictionary = try Data(contentsOf: IFDictionaryFiles.child(IFDictionaryCatalog.dictionaryFilename, in: reuse))
        guard manifest.formatVersion == 1, manifest.recipeVersion == IFDictionaryCatalog.recipeVersion,
              manifest.dictionarySHA256 == IFDictionaryHash.sha256(dictionary),
              manifest.correctionsSHA256 == (try IFDictionaryFiles.hash(runtime.resources.appendingPathComponent(IFDictionaryCatalog.correctionsFilename))) else {
            // Changed correction policy requires regeneration from verified source bytes, never stale correction overlays.
            throw IFDictionaryUpdateError(.prepare, "rebuild-integrity")
        }
    } else {
        let specs = IFDictionaryCatalog.sources.filter(\.isUpdatable)
        guard request.receipts.map(\.id) == specs.map(\.id) else { throw IFDictionaryUpdateError(.prepare, "source-set") }
        var inputs = try request.receipts.map { receipt in
            IFDictionaryInput(receipt: receipt, data: try Data(contentsOf: IFDictionaryFiles.child("raw/\(receipt.id).dict.yaml", in: root)))
        }
        let legacy = IFDictionaryCatalog.sources.last!
        inputs.append(.init(receipt: legacy.pinnedReceipt,
            data: try Data(contentsOf: runtime.resources.appendingPathComponent(IFDictionaryCatalog.legacyFilename))))
        let generation = try IFDictionaryGenerator.generate(inputs: inputs,
            corrections: Data(contentsOf: runtime.resources.appendingPathComponent(IFDictionaryCatalog.correctionsFilename)))
        dictionary = generation.dictionary; manifest = generation.manifest
    }
    if request.existing == .init(contentVersion: manifest.contentVersion, runtimeFingerprint: request.runtimeFingerprint) {
        try emit(.init(result: .init(outcome: .contentUnchanged, manifest: manifest)))
        exit(0)
    }
    operation = "copy-current-resources"
    let shared = try IFDictionaryFiles.child("shared", in: root)
    guard !FileManager.default.fileExists(atPath: shared.path) else { throw IFDictionaryUpdateError(.prepare, "candidate-not-empty") }
    // These are only immutable, app-owned resources, never downloaded schema or Lua configuration.
    _ = try IFDictionaryFiles.hashes(in: runtime.resources)
    try FileManager.default.copyItem(at: runtime.resources, to: shared)
    operation = "write-generated-dictionary"
    try IFDictionaryFiles.atomicWrite(dictionary, to: shared.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
    try IFDictionaryFiles.atomicWrite(manifest.encoded(), to: shared.appendingPathComponent(IFDictionaryManifest.filename))
    operation = "create-isolated-directories"
    let cache = try IFDictionaryFiles.child("cache", in: root)
    let compiler = try IFDictionaryFiles.child("compile-user", in: root)
    let probe = try IFDictionaryFiles.child("probe-user", in: root)
    for directory in [cache, compiler, probe] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
    try emit(.init(progress: .init(stage: .prepare, completed: 1, total: 2)))
    operation = "compile"
    guard IFDictionaryCompile(shared.path, compiler.path, cache.path) == 0 else {
        throw IFDictionaryUpdateError(.prepare, "rime-compile")
    }
    stage = .verify
    try emit(.init(progress: .init(stage: .verify, completed: 0, total: 1)))
    operation = "clean-smoke"
    let status = IFDictionaryProbe(shared.path, probe.path, cache.path)
    guard status == 0 else { throw IFDictionaryUpdateError(.verify, "smoke-probe", detail: "probe=\(status)") }
    let required = ["inkflow_pinyin.schema.yaml", "pinyin_simp.table.bin", "pinyin_simp.prism.bin", "easy_en.table.bin", "inkflow_mixed.table.bin"] + InputPreferences.compiledSpellingFiles
    for name in required where !FileManager.default.fileExists(atPath: cache.appendingPathComponent(name).path) {
        throw IFDictionaryUpdateError(.verify, "compiled-file-missing", file: name)
    }
    operation = "remove-isolated-scratch"
    // Retain only reusable products; isolated learning and deployment scratch are disposable.
    for name in ["compile-user", "probe-user", "rebuild", "request.json"] {
        let path = try IFDictionaryFiles.child(name, in: root)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    operation = "seal-prepared-resources"
    var hashes = [String: String]()
    for (path, hash) in try IFDictionaryFiles.hashes(in: shared) { hashes["shared/\(path)"] = hash }
    for (path, hash) in try IFDictionaryFiles.hashes(in: cache) { hashes["cache/\(path)"] = hash }
    let raw = try IFDictionaryFiles.child("raw", in: root)
    if FileManager.default.fileExists(atPath: raw.path) {
        for (path, hash) in try IFDictionaryFiles.hashes(in: raw) { hashes["raw/\(path)"] = hash }
    }
    let prepared = IFDictionaryPreparedReceipt(contentVersion: manifest.contentVersion, runtimeFingerprint: request.runtimeFingerprint, files: hashes)
    try IFDictionaryFiles.atomicWrite(IFDictionaryFiles.encode(prepared), to: root.appendingPathComponent(IFDictionaryPreparedReceipt.filename))
    try emit(.init(progress: .init(stage: .verify, completed: 1, total: 1), result: .init(outcome: .prepared, manifest: manifest)))
} catch {
    let failure = IFDictionaryUpdateError.wrapping(error, stage: stage)
    try? emit(.init(failure: .init(failure.stage, failure.code, source: failure.source, file: failure.file,
        detail: "operation=\(operation); \(failure.detail)")))
    exit(1)
}
