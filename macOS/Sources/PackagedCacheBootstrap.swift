import Foundation

package enum IFPackagedCacheToolBootstrap {
    package typealias EngineOperation = (_ shared: String, _ user: String, _ cache: String) -> Int32

    package static func run(arguments: [String], compile: EngineOperation, probe: EngineOperation) throws {
        guard arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        let resources = URL(fileURLWithPath: arguments[1])
        let scratch = URL(fileURLWithPath: arguments[2])
        let verify = arguments[3] == "--verify"
        let cache = resources.deletingLastPathComponent().appendingPathComponent(IFPackagedCache.directory)
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        if !verify {
            if fm.fileExists(atPath: cache.path) { try fm.removeItem(at: cache) }
            try fm.createDirectory(at: cache, withIntermediateDirectories: false)
            let compiler = scratch.appendingPathComponent("compiler")
            try fm.createDirectory(at: compiler, withIntermediateDirectories: false)
            guard compile(resources.path, compiler.path, cache.path) == 0 else {
                throw IFDictionaryUpdateError(.prepare, "packaged-cache-compile")
            }
            let manifest = try IFDictionaryFiles.decode(IFDictionaryManifest.self,
                at: resources.appendingPathComponent(IFDictionaryManifest.filename))
            let receipt = IFPackagedCache(formatVersion: 1, contentVersion: manifest.contentVersion,
                resources: try IFDictionaryFiles.hashes(in: resources), compiled: try IFPackagedCache.compiledHashes(cache))
            try IFDictionaryFiles.atomicWrite(IFDictionaryFiles.encode(receipt),
                to: cache.appendingPathComponent(IFPackagedCache.filename))
        }
        _ = try IFPackagedCache.descriptor(resources: resources)
        let before = try IFPackagedCache.compiledHashes(cache)
        let probeRoot = scratch.appendingPathComponent("probe")
        try fm.createDirectory(at: probeRoot, withIntermediateDirectories: false)
        guard probe(resources.path, probeRoot.path, cache.path) == 0 else {
            throw IFDictionaryUpdateError(.verify, "packaged-cache-probe")
        }
        guard try IFPackagedCache.compiledHashes(cache) == before else {
            throw IFDictionaryUpdateError(.verify, "packaged-cache-mutated")
        }
        print("PASS packaged cache: resource/cache hashes, required profiles, clean Chinese/mixed/English/emoji probe, no cache mutation")
    }
}
