import Foundation

/// App-owned compiled resources. This receipt binds data bytes, not binaries changed by signing.
struct IFPackagedCache: Codable {
    static let directory = "RimePrebuilt"
    static let filename = "inkflow-cache.json"
    let formatVersion: Int
    let contentVersion: String
    let resources: [String: String]
    let compiled: [String: String]

    static func descriptor(resources: URL) throws -> IFDictionaryDescriptor {
        let cache = resources.deletingLastPathComponent().appendingPathComponent(directory)
        let receipt = try IFDictionaryFiles.decode(Self.self, at: cache.appendingPathComponent(filename))
        let manifest = try IFDictionaryFiles.decode(IFDictionaryManifest.self, at: resources.appendingPathComponent(IFDictionaryManifest.filename))
        try IFDictionaryStore.validateMetadata(manifest)
        guard receipt.formatVersion == 1, receipt.contentVersion == manifest.contentVersion,
              receipt.resources[IFDictionaryCatalog.dictionaryFilename] == manifest.dictionarySHA256,
              receipt.resources == (try IFDictionaryFiles.hashes(in: resources)),
              receipt.compiled == (try compiledHashes(cache)) else {
            throw IFDictionaryUpdateError(.recovery, "packaged-cache-integrity")
        }
        let required = ["inkflow_pinyin.schema.yaml", "pinyin_simp.table.bin", "pinyin_simp.prism.bin",
                        "pinyin_simp.reverse.bin", "easy_en.table.bin", "inkflow_mixed.table.bin"] + InputPreferences.compiledSpellingFiles
        guard required.allSatisfy({ receipt.compiled[$0] != nil }) else {
            throw IFDictionaryUpdateError(.recovery, "packaged-cache-incomplete")
        }
        return .init(version: nil, manifest: manifest, sharedData: resources, cache: cache)
    }

    static func compiledHashes(_ cache: URL) throws -> [String: String] {
        var values = try IFDictionaryFiles.hashes(in: cache)
        values.removeValue(forKey: filename)
        return values
    }
}
