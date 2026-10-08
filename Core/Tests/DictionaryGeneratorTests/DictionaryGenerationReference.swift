import Foundation
import InkFlowDomain

extension DictionaryGeneratorTests {
    private struct ReferenceCase: Decodable {
        let name: String
        let bodies: [String: String]?
        let header: String?
        let corrections: String?
    }

    static func exportReference(cases: URL, output: URL) throws {
        let cases = try JSONDecoder().decode([ReferenceCase].self, from: Data(contentsOf: cases))
        var results = [String: Any]()
        for test in cases {
            let (inputs, catalog) = fixture(test.bodies ?? [:], header: test.header ?? "---\nimport_tables: [ignored]\n...\n")
            do {
                let generated = try IFReferenceDictionaryGenerator.generate(inputs: inputs,
                    corrections: Data((test.corrections ?? "").utf8), catalog: catalog)
                var schemas = try IFReferenceSpellingGenerator.generate(dictionary: generated.dictionary)
                schemas[IFDictionaryCatalog.contextIndexFilename] = try IFContextRanker.buildIndex(dictionary: generated.dictionary)
                results[test.name] = [
                    "manifest": try JSONSerialization.jsonObject(with: generated.manifest.encoded()),
                    "spellingSHA256": schemas.mapValues { IFDictionaryHash.sha256($0) }
                ]
            } catch let error as IFDictionaryError {
                var failure: [String: Any] = ["code": error.code]
                if let source = error.source { failure["source"] = source }
                if let line = error.line { failure["line"] = line }
                results[test.name] = ["error": failure]
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try encoder.encode(IFDictionaryCatalog.sources).write(to: output.appendingPathComponent("catalog.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: output.appendingPathComponent("reference.json"), options: .atomic)
        print("Exported Swift dictionary contract: \(cases.count) cases")
    }
}
