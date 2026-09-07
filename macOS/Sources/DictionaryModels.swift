import Foundation
import CryptoKit

struct IFDictionarySourceSpec: Codable, Equatable, Sendable {
    let id: String
    let group: String
    let name: String
    let repository: String
    let branch: String
    let path: String
    let pinnedCommit: String
    let pinnedBlobSHA: String
    let pinnedSHA256: String
    let pinnedByteCount: Int
    var isUpdatable: Bool { group != "legacy" }
    var pinnedReceipt: IFDictionarySourceReceipt {
        IFDictionarySourceReceipt(id: id, commit: pinnedCommit, blobSHA: pinnedBlobSHA,
                                  sha256: pinnedSHA256, byteCount: pinnedByteCount, recordCount: 0)
    }
    func rawURL(commit: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(repository)/\(commit)/\(path)")!
    }
    func sourceURL(commit: String) -> URL {
        URL(string: "https://github.com/\(repository)/blob/\(commit)/\(path)")!
    }
}

struct IFDictionarySourceReceipt: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let repository: String
    let path: String
    let commit: String
    let blobSHA: String
    let sha256: String
    let byteCount: Int
    var recordCount: Int

    init(id: String, commit: String, blobSHA: String, sha256: String, byteCount: Int, recordCount: Int,
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

struct IFDictionaryCalibrationBucket: Codable, Equatable, Sendable {
    let syllables: Int
    let pairCount: Int
    let multiplier: Double
    let usedOverall: Bool
}

struct IFDictionaryCalibration: Codable, Equatable, Sendable {
    let sourceGroup: String
    let pairCount: Int
    let overallMultiplier: Double
    let buckets: [IFDictionaryCalibrationBucket]
}

struct IFDictionaryManifest: Codable, Equatable, Sendable {
    static let filename = "dictionary-manifest.json"
    let formatVersion: Int
    let recipeVersion: Int
    let contentVersion: String
    let entryCount: Int
    let contentSHA256: String
    let dictionarySHA256: String
    let correctionsSHA256: String
    let sources: [IFDictionarySourceReceipt]
    let calibrations: [IFDictionaryCalibration]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0a)
        return data
    }
}

struct IFDictionaryInput: Sendable {
    let receipt: IFDictionarySourceReceipt
    let data: Data
}

struct IFDictionaryGeneration: Sendable {
    let dictionary: Data
    let manifest: IFDictionaryManifest
}

struct IFDictionaryError: Error, LocalizedError, Sendable {
    let code: String
    let source: String?
    let line: Int?
    let detail: String
    init(_ code: String, source: String? = nil, line: Int? = nil, _ detail: String) {
        self.code = code; self.source = source; self.line = line; self.detail = detail
    }
    var errorDescription: String? {
        [code, source, line.map { "line \($0)" }, detail].compactMap { $0 }.joined(separator: ": ")
    }
}

enum IFDictionaryHash {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func gitBlob(_ data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum IFDictionaryCatalog {
    static let recipeVersion = 1
    static let dictionaryFilename = "pinyin_simp.dict.yaml"
    static let legacyFilename = "legacy-pinyin-simp.dict.yaml"
    static let correctionsFilename = "chinese-overrides.tsv"
    static let maximumSourceBytes = 128 * 1024 * 1024
    static let initialEntryCount = 963_978
    static let sources: [IFDictionarySourceSpec] = [
        .init(id: "frost-8105", group: "frost", name: "白霜 · 字表", repository: "gaboolic/rime-frost", branch: "master", path: "cn_dicts/8105.dict.yaml", pinnedCommit: "19167adfe67fcba2f65c336117557639ff254ddb", pinnedBlobSHA: "9cbfe2acf59bb3124993d4b8b3b271f8e246b72d", pinnedSHA256: "5a6bb545d07140406208728aeed70706e84279daeee132f10b069cd6387a042a", pinnedByteCount: 99_367),
        .init(id: "frost-base", group: "frost", name: "白霜 · 基础", repository: "gaboolic/rime-frost", branch: "master", path: "cn_dicts/base.dict.yaml", pinnedCommit: "19167adfe67fcba2f65c336117557639ff254ddb", pinnedBlobSHA: "973beb1203cfd3340b4829d984f193feaf72e3cf", pinnedSHA256: "9067f23b4505e57f5e380b154e22fb2fbbf2111ab0611f8bc6e8b82efa90b891", pinnedByteCount: 9_937_947),
        .init(id: "frost-ext", group: "frost", name: "白霜 · 扩展", repository: "gaboolic/rime-frost", branch: "master", path: "cn_dicts/ext.dict.yaml", pinnedCommit: "19167adfe67fcba2f65c336117557639ff254ddb", pinnedBlobSHA: "6b8a6c84c6c7b638f099b6d2a5a91f35662fb767", pinnedSHA256: "44b78e4feb8a3b302298844061626aa4e2194901b8ed4ee6acec84261b6aa90d", pinnedByteCount: 7_711_375),
        .init(id: "frost-idiom", group: "frost", name: "白霜 · 成语与诗句", repository: "gaboolic/rime-frost", branch: "master", path: "cn_dicts_cell/idiom.dict.yaml", pinnedCommit: "19167adfe67fcba2f65c336117557639ff254ddb", pinnedBlobSHA: "c9bf62a4de8b10efa6aec1dca56fe3e423bf240e", pinnedSHA256: "341d777d4fd077ddb534e47f8ba27a8dd80d085fd0b847548a97a6666d644113", pinnedByteCount: 1_665_339),
        .init(id: "ice-base", group: "ice", name: "雾凇 · 基础", repository: "iDvel/rime-ice", branch: "main", path: "cn_dicts/base.dict.yaml", pinnedCommit: "fbb516b2786e4d5444383706d13c31c2e4d10c08", pinnedBlobSHA: "af59fe3a2259ed91ae642aab09422599a0557017", pinnedSHA256: "6c594bbd03425600aa36894b713f3d268bd2a11099833a312160249e0a3f0082", pinnedByteCount: 16_620_279),
        .init(id: "ice-ext", group: "ice", name: "雾凇 · 扩展", repository: "iDvel/rime-ice", branch: "main", path: "cn_dicts/ext.dict.yaml", pinnedCommit: "fbb516b2786e4d5444383706d13c31c2e4d10c08", pinnedBlobSHA: "0a3d5aa7e1bb1dc73f8d73448a1986031ae6819e", pinnedSHA256: "5435dd8b75d6eb688787a25b6e302867152ef401bec7b263136ab1e2a2ecf4ae", pinnedByteCount: 11_923_397),
        .init(id: "legacy", group: "legacy", name: "旧版拼音 · 兼容增量", repository: "rime/rime-pinyin-simp", branch: "master", path: "pinyin_simp.dict.yaml", pinnedCommit: "0c6861ef7420ee780270ca6d993d18d4101049d0", pinnedBlobSHA: "6f2e996d2792416cb7f41bb49967a1dec7060c92", pinnedSHA256: "e341598343a0f0f2035bb1aafc34a7f3bb7887deeecb3f60796262aaa2983e6b", pinnedByteCount: 1_266_216)
    ]
}
