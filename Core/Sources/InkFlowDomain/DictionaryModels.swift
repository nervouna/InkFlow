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
    package static let recipeVersion = IFDictionaryGenerator.recipeVersion
    package static let dictionaryFilename = "pinyin_simp.dict.yaml"
    package static let contextIndexFilename = "pinyin_simp.context.bin"
    package static let legacyFilename = "legacy-pinyin-simp.dict.yaml"
    package static let correctionsFilename = "chinese-overrides.tsv"
    package static let maximumSourceBytes = IFDictionaryGenerator.maximumSourceBytes
    package static let initialEntryCount = 965_919
    package static let sources = IFDictionaryGenerator.catalog()
}
