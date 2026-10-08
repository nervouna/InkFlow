import InkFlowDomain
import Foundation

/// Resource preparation runs in an isolated runtime supplied by the host. It never launches a process.
package enum IFDictionaryPreparation {
    package typealias EngineOperation = (_ shared: String, _ user: String, _ cache: String) -> Int32

    package static func prepare(request: IFDictionaryWorkerRequest, runtime: IFDictionaryRuntime,
                                compile: EngineOperation, probe: EngineOperation,
                                emit: (IFDictionaryWorkerEvent) throws -> Void = { _ in }) throws -> IFDictionaryWorkerResult {
        let root = request.candidate
        var stage = IFDictionaryStage.prepare
        var operation = "runtime-fingerprint"
        do {
            guard try runtime.fingerprint() == request.runtimeFingerprint else {
                throw IFDictionaryUpdateError(.prepare, "runtime-changed")
            }
            try emit(.init(progress: .init(stage: .prepare, completed: 0, total: 2)))
            operation = "generate-dictionary"
            let dictionary: Data
            let manifest: IFDictionaryManifest
            if request.reuseDictionary {
                guard request.receipts.isEmpty else { throw IFDictionaryUpdateError(.prepare, "source-set") }
                let reuse = try IFDictionaryFiles.child("rebuild", in: root)
                manifest = try IFDictionaryFiles.decode(IFDictionaryManifest.self,
                    at: IFDictionaryFiles.child(IFDictionaryManifest.filename, in: reuse))
                try IFDictionaryStore.validateMetadata(manifest)
                dictionary = try Data(contentsOf: IFDictionaryFiles.child(IFDictionaryCatalog.dictionaryFilename, in: reuse))
                guard manifest.formatVersion == 1, manifest.recipeVersion == IFDictionaryCatalog.recipeVersion,
                      manifest.dictionarySHA256 == IFDictionaryHash.sha256(dictionary),
                      manifest.correctionsSHA256 == (try IFDictionaryFiles.hash(
                        runtime.resources.appendingPathComponent(IFDictionaryCatalog.correctionsFilename))) else {
                    throw IFDictionaryUpdateError(.prepare, "rebuild-integrity")
                }
            } else {
                let specs = IFDictionaryCatalog.sources.filter(\.isUpdatable)
                guard request.receipts.map(\.id) == specs.map(\.id) else {
                    throw IFDictionaryUpdateError(.prepare, "source-set")
                }
                var inputs = try request.receipts.map { receipt in
                    IFDictionaryInput(receipt: receipt, data: try Data(contentsOf:
                        IFDictionaryFiles.child("raw/\(receipt.id).dict.yaml", in: root)))
                }
                let legacy = IFDictionaryCatalog.sources.last!
                inputs.append(.init(receipt: legacy.pinnedReceipt,
                    data: try Data(contentsOf: runtime.resources.appendingPathComponent(IFDictionaryCatalog.legacyFilename))))
                let generation = try IFDictionaryGenerator.generate(inputs: inputs,
                    corrections: Data(contentsOf: runtime.resources.appendingPathComponent(IFDictionaryCatalog.correctionsFilename)))
                dictionary = generation.dictionary
                manifest = generation.manifest
            }
            if request.existing == .init(contentVersion: manifest.contentVersion,
                                         runtimeFingerprint: request.runtimeFingerprint) {
                try emit(.init(result: .init(outcome: .contentUnchanged, manifest: manifest)))
                return .init(outcome: .contentUnchanged, manifest: manifest)
            }
            operation = "copy-current-resources"
            let shared = try IFDictionaryFiles.child("shared", in: root)
            guard !FileManager.default.fileExists(atPath: shared.path) else {
                throw IFDictionaryUpdateError(.prepare, "candidate-not-empty")
            }
            _ = try IFDictionaryFiles.hashes(in: runtime.resources)
            try FileManager.default.copyItem(at: runtime.resources, to: shared)
            operation = "write-generated-dictionary"
            try IFDictionaryFiles.atomicWrite(dictionary,
                to: shared.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename))
            try IFDictionaryFiles.atomicWrite(manifest.encoded(),
                to: shared.appendingPathComponent(IFDictionaryManifest.filename))
            operation = "generate-spelling"
            let spelling = try IFSpellingGenerator.generate(dictionary: dictionary)
            for name in spelling.keys.sorted() {
                // Keep replacement staging inside the sandbox's candidate directory.
                try IFDictionaryFiles.atomicWrite(spelling[name]!, to: shared.appendingPathComponent(name))
            }
            operation = "generate-context-index"
            try IFDictionaryFiles.atomicWrite(IFContextRanker.buildIndex(dictionary: dictionary),
                to: shared.appendingPathComponent(IFDictionaryCatalog.contextIndexFilename))
            operation = "create-isolated-directories"
            let cache = try IFDictionaryFiles.child("cache", in: root)
            let compiler = try IFDictionaryFiles.child("compile-user", in: root)
            let probeRoot = try IFDictionaryFiles.child("probe-user", in: root)
            for directory in [cache, compiler, probeRoot] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            try emit(.init(progress: .init(stage: .prepare, completed: 1, total: 2)))
            operation = "compile"
            guard compile(shared.path, compiler.path, cache.path) == 0 else {
                throw IFDictionaryUpdateError(.prepare, "rime-compile")
            }
            stage = .verify
            try emit(.init(progress: .init(stage: .verify, completed: 0, total: 1)))
            operation = "clean-smoke"
            let status = probe(shared.path, probeRoot.path, cache.path)
            guard status == 0 else {
                throw IFDictionaryUpdateError(.verify, "smoke-probe", detail: "probe=\(status)")
            }
            let required = ["inkflow_pinyin.schema.yaml", "pinyin_simp.table.bin", "pinyin_simp.prism.bin",
                            "easy_en.table.bin", "inkflow_mixed.table.bin"] + InputPreferences.compiledSpellingFiles
            for name in required where !FileManager.default.fileExists(atPath: cache.appendingPathComponent(name).path) {
                throw IFDictionaryUpdateError(.verify, "compiled-file-missing", file: name)
            }
            operation = "remove-isolated-scratch"
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
            let prepared = IFDictionaryPreparedReceipt(contentVersion: manifest.contentVersion,
                runtimeFingerprint: request.runtimeFingerprint, files: hashes)
            try IFDictionaryFiles.atomicWrite(IFDictionaryFiles.encode(prepared),
                to: root.appendingPathComponent(IFDictionaryPreparedReceipt.filename))
            try emit(.init(progress: .init(stage: .verify, completed: 1, total: 1),
                           result: .init(outcome: .prepared, manifest: manifest)))
            return .init(outcome: .prepared, manifest: manifest)
        } catch {
            let failure = IFDictionaryUpdateError.wrapping(error, stage: stage)
            throw IFDictionaryUpdateError(failure.stage, failure.code, source: failure.source, file: failure.file,
                detail: "operation=\(operation); \(failure.detail)")
        }
    }

    package static func stage(candidate: URL, inputs: [IFDictionaryInput], runtime: IFDictionaryRuntime,
                          existing: IFDictionaryContentIdentity? = nil,
                          checkCancellation: () throws -> Void = {}) throws -> IFDictionaryWorkerRequest {
        try checkCancellation()
        guard inputs.map(\.receipt.id) == IFDictionaryCatalog.sources.filter(\.isUpdatable).map(\.id) else {
            throw IFDictionaryUpdateError(.prepare, "source-set")
        }
        let raw = try IFDictionaryFiles.child("raw", in: candidate)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: false)
        for input in inputs {
            try checkCancellation()
            try IFDictionaryGenerator.validate(input)
            try input.data.write(to: IFDictionaryFiles.child(input.receipt.id + ".dict.yaml", in: raw), options: .withoutOverwriting)
        }
        try checkCancellation()
        let request = IFDictionaryWorkerRequest(candidate: candidate, runtimeFingerprint: try runtime.fingerprint(),
            receipts: inputs.map(\.receipt), reuseDictionary: false, existing: existing)
        return request
    }

    package static func stageRebuild(candidate: URL, dictionaryShared: URL, runtime: IFDictionaryRuntime,
                                 checkCancellation: () throws -> Void = {}) throws -> IFDictionaryWorkerRequest {
        try checkCancellation()
        let manifest = try IFDictionaryFiles.decode(IFDictionaryManifest.self, at: IFDictionaryFiles.child(IFDictionaryManifest.filename, in: dictionaryShared))
        let retainedRaw = dictionaryShared.deletingLastPathComponent().appendingPathComponent("raw")
        if FileManager.default.fileExists(atPath: retainedRaw.path) {
            let inputs = try manifest.sources.filter { $0.id != "legacy" }.map { receipt in
                try checkCancellation()
                return IFDictionaryInput(receipt: receipt, data: try Data(contentsOf: IFDictionaryFiles.child(receipt.id + ".dict.yaml", in: retainedRaw)))
            }
            return try stage(candidate: candidate, inputs: inputs, runtime: runtime, checkCancellation: checkCancellation)
        }
        let reuse = try IFDictionaryFiles.child("rebuild", in: candidate)
        try FileManager.default.createDirectory(at: reuse, withIntermediateDirectories: false)
        for name in [IFDictionaryCatalog.dictionaryFilename, IFDictionaryManifest.filename] {
            try checkCancellation()
            try FileManager.default.copyItem(at: IFDictionaryFiles.child(name, in: dictionaryShared), to: reuse.appendingPathComponent(name))
        }
        try checkCancellation()
        let request = IFDictionaryWorkerRequest(candidate: candidate, runtimeFingerprint: try runtime.fingerprint(), receipts: [],
            reuseDictionary: true, existing: nil)
        return request
    }
}
