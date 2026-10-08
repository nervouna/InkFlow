import Foundation
import CryptoKit

package struct IFDictionarySourceSpec: Codable, Equatable, Sendable {
    package let id: String
    package let group: String
    package let name: String
    package let repository: String
    package let branch: String
    package let path: String
    package let pinnedCommit: String
    package let pinnedBlobSHA: String
    package let pinnedSHA256: String
    package let pinnedByteCount: Int
    package var defaultWeight: Int? = nil
    package var isUpdatable: Bool { group != "legacy" }
    package var pinnedReceipt: IFDictionarySourceReceipt {
        IFDictionarySourceReceipt(id: id, commit: pinnedCommit, blobSHA: pinnedBlobSHA,
                                  sha256: pinnedSHA256, byteCount: pinnedByteCount, recordCount: 0)
    }
    package func rawURL(commit: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(repository)/\(commit)/\(path)")!
    }
    package func sourceURL(commit: String) -> URL {
        URL(string: "https://github.com/\(repository)/blob/\(commit)/\(path)")!
    }
}

package struct IFDictionarySourceReceipt: Codable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let repository: String
    package let path: String
    package let commit: String
    package let blobSHA: String
    package let sha256: String
    package let byteCount: Int
    package var recordCount: Int

    package init(id: String, commit: String, blobSHA: String, sha256: String, byteCount: Int, recordCount: Int,
         name: String? = nil, repository: String? = nil, path: String? = nil) {
        let spec = IFDictionaryCatalog.sources.first { $0.id == id }
        self.id = id
        self.name = name ?? spec?.name ?? id
        self.repository = repository ?? spec?.repository ?? ""
        self.path = path ?? spec?.path ?? ""
        self.commit = commit
        self.blobSHA = blobSHA
        self.sha256 = sha256
        self.byteCount = byteCount
        self.recordCount = recordCount
    }
}

package struct IFDictionaryCalibrationBucket: Codable, Equatable, Sendable {
    package let syllables: Int
    package let pairCount: Int
    package let multiplier: Double
    package let usedOverall: Bool
}

package struct IFDictionaryCalibration: Codable, Equatable, Sendable {
    package let sourceGroup: String
    package let pairCount: Int
    package let overallMultiplier: Double
    package let buckets: [IFDictionaryCalibrationBucket]
}

package struct IFDictionaryManifest: Codable, Equatable, Sendable {
    package static let filename = "dictionary-manifest.json"
    package let formatVersion: Int
    package let recipeVersion: Int
    package let contentVersion: String
    package let entryCount: Int
    package let contentSHA256: String
    package let dictionarySHA256: String
    package let correctionsSHA256: String
    package let sources: [IFDictionarySourceReceipt]
    package let calibrations: [IFDictionaryCalibration]

    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0a)
        return data
    }
}

package struct IFDictionaryInput: Sendable {
    package let receipt: IFDictionarySourceReceipt
    package let data: Data
    package init(receipt: IFDictionarySourceReceipt,
        data: Data) {
        self.receipt = receipt
        self.data = data
    }

}

package struct IFDictionaryGeneration: Sendable {
    package let dictionary: Data
    package let manifest: IFDictionaryManifest
}

package struct IFDictionaryError: Error, LocalizedError, Sendable {
    package let code: String
    package let source: String?
    package let line: Int?
    package let detail: String
    package init(_ code: String, source: String? = nil, line: Int? = nil, _ detail: String) {
        self.code = code; self.source = source; self.line = line; self.detail = detail
    }
    package var errorDescription: String? {
        [code, source, line.map { "line \($0)" }, detail].compactMap { $0 }.joined(separator: ": ")
    }
}

package enum IFDictionaryHash {
    package static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    package static func gitBlob(_ data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    package static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

package enum IFDictionaryCatalog {
    package static let recipeVersion = 2
    package static let dictionaryFilename = "pinyin_simp.dict.yaml"
    package static let contextIndexFilename = "pinyin_simp.context.bin"
    package static let legacyFilename = "legacy-pinyin-simp.dict.yaml"
    package static let correctionsFilename = "chinese-overrides.tsv"
    package static let maximumSourceBytes = 128 * 1024 * 1024
    package static let initialEntryCount = 969_894
    package static let sources: [IFDictionarySourceSpec] = [
        .init(id: "frost-8105", group: "frost", name: "白霜 · 字表", repository: "gaboolic/rime-frost", branch: "master", path: "cn_dicts/8105.dict.yaml", pinnedCommit: "19167adfe67fcba2f65c336117557639ff254ddb", pinnedBlobSHA: "9cbfe2acf59bb3124993d4b8b3b271f8e246b72d", pinnedSHA256: "5a6bb545d07140406208728aeed70706e84279daeee132f10b069cd6387a042a", pinnedByteCount: 99_367),
        .init(id: "frost-base", group: "frost", name: "白霜 · 基础", repository: "gaboolic/rime-frost", branch: "master", path: "cn_dicts/base.dict.yaml", pinnedCommit: "19167adfe67fcba2f65c336117557639ff254ddb", pinnedBlobSHA: "973beb1203cfd3340b4829d984f193feaf72e3cf", pinnedSHA256: "9067f23b4505e57f5e380b154e22fb2fbbf2111ab0611f8bc6e8b82efa90b891", pinnedByteCount: 9_937_947),
        .init(id: "frost-ext", group: "frost", name: "白霜 · 扩展", repository: "gaboolic/rime-frost", branch: "master", path: "cn_dicts/ext.dict.yaml", pinnedCommit: "19167adfe67fcba2f65c336117557639ff254ddb", pinnedBlobSHA: "6b8a6c84c6c7b638f099b6d2a5a91f35662fb767", pinnedSHA256: "44b78e4feb8a3b302298844061626aa4e2194901b8ed4ee6acec84261b6aa90d", pinnedByteCount: 7_711_375),
        .init(id: "frost-idiom", group: "frost", name: "白霜 · 成语与诗句", repository: "gaboolic/rime-frost", branch: "master", path: "cn_dicts_cell/idiom.dict.yaml", pinnedCommit: "19167adfe67fcba2f65c336117557639ff254ddb", pinnedBlobSHA: "c9bf62a4de8b10efa6aec1dca56fe3e423bf240e", pinnedSHA256: "341d777d4fd077ddb534e47f8ba27a8dd80d085fd0b847548a97a6666d644113", pinnedByteCount: 1_665_339),
        .init(id: "ice-base", group: "ice", name: "雾凇 · 基础", repository: "iDvel/rime-ice", branch: "main", path: "cn_dicts/base.dict.yaml", pinnedCommit: "fbb516b2786e4d5444383706d13c31c2e4d10c08", pinnedBlobSHA: "af59fe3a2259ed91ae642aab09422599a0557017", pinnedSHA256: "6c594bbd03425600aa36894b713f3d268bd2a11099833a312160249e0a3f0082", pinnedByteCount: 16_620_279),
        .init(id: "ice-ext", group: "ice", name: "雾凇 · 扩展", repository: "iDvel/rime-ice", branch: "main", path: "cn_dicts/ext.dict.yaml", pinnedCommit: "fbb516b2786e4d5444383706d13c31c2e4d10c08", pinnedBlobSHA: "0a3d5aa7e1bb1dc73f8d73448a1986031ae6819e", pinnedSHA256: "5435dd8b75d6eb688787a25b6e302867152ef401bec7b263136ab1e2a2ecf4ae", pinnedByteCount: 11_923_397),
        .init(id: "frost-computer", group: "specialty", name: "白霜 · 计算机", repository: "gaboolic/rime-frost", branch: "master", path: "cn_dicts_cell/computer.dict.yaml", pinnedCommit: "19167adfe67fcba2f65c336117557639ff254ddb", pinnedBlobSHA: "0a9592d65d3bfd15116b3b48a45268a81b2716fa", pinnedSHA256: "a92fe61d48b53d1d20f1e66be4ca83ac2e8be0caa1fa3f383c5c15de6cb7d5ea", pinnedByteCount: 1_030),
        .init(id: "frost-exthot", group: "specialty", name: "白霜 · 网络热词", repository: "gaboolic/rime-frost", branch: "master", path: "cn_dicts_cell/exthot.dict.yaml", pinnedCommit: "19167adfe67fcba2f65c336117557639ff254ddb", pinnedBlobSHA: "caa7b822e2e994262ec660d3416ba174b151cc74", pinnedSHA256: "d5f8bda70bb621f82ed85e4e8dbe8386c81effb856ff82ebb5c708d18ae993c1", pinnedByteCount: 50_277),
        .init(id: "selected-computer", group: "specialty", name: "搜狗 · 计算机词汇（Rime 转换）", repository: "alswl/rime-selected", branch: "master", path: "selected.jisuanjicihuidaquan.dict.yaml", pinnedCommit: "30d61877615dbee98c3b5b4322d50bdc90226816", pinnedBlobSHA: "c61a17b7878a15e418569266b0e58f086789a4c4", pinnedSHA256: "804f55821591e112d10df1e78445f945e70f7204c2a9521d2a72c048003fc3e0", pinnedByteCount: 309_467, defaultWeight: 1),
        .init(id: "legacy", group: "legacy", name: "旧版拼音 · 兼容增量", repository: "rime/rime-pinyin-simp", branch: "master", path: "pinyin_simp.dict.yaml", pinnedCommit: "0c6861ef7420ee780270ca6d993d18d4101049d0", pinnedBlobSHA: "6f2e996d2792416cb7f41bb49967a1dec7060c92", pinnedSHA256: "e341598343a0f0f2035bb1aafc34a7f3bb7887deeecb3f60796262aaa2983e6b", pinnedByteCount: 1_266_216)
    ]
}
