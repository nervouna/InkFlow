import InkFlowDomain
import Foundation

/// App-owned compiled resources. This receipt binds data bytes, not binaries changed by signing.
package struct IFPackagedCache: Codable {
    package static let directory = "RimePrebuilt"
    package static let filename = "inkflow-cache.json"
    package let formatVersion: Int
    package let contentVersion: String
    package let resources: [String: String]
    package let compiled: [String: String]

    package static func descriptor(resources: URL) throws -> IFDictionaryDescriptor {
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

    package static func compiledHashes(_ cache: URL) throws -> [String: String] {
        var values = try IFDictionaryFiles.hashes(in: cache)
        values.removeValue(forKey: filename)
        return values
    }
}
