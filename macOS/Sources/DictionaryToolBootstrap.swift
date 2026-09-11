import Foundation

package enum IFDictionaryToolBootstrap {
    package static func run(arguments: [String]) throws {
        if arguments == ["sources"] {
            for spec in IFDictionaryCatalog.sources where spec.isUpdatable {
                print("\(spec.id)\t\(spec.pinnedSHA256)\t\(spec.pinnedByteCount)\t\(spec.rawURL(commit: spec.pinnedCommit).absoluteString)")
            }
        } else if arguments.count == 5, arguments[0] == "generate" {
            let sourceDirectory = URL(fileURLWithPath: arguments[1])
            let legacy = URL(fileURLWithPath: arguments[2])
            let corrections = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
            let output = URL(fileURLWithPath: arguments[4])
            let inputs = try IFDictionaryCatalog.sources.map { spec in
                IFDictionaryInput(receipt: spec.pinnedReceipt, data: try Data(contentsOf:
                    spec.isUpdatable ? sourceDirectory.appendingPathComponent(spec.id + ".yaml") : legacy))
            }
            let result = try IFDictionaryGenerator.generate(inputs: inputs, corrections: corrections)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try result.dictionary.write(to: output.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename), options: .atomic)
            try result.manifest.encoded().write(to: output.appendingPathComponent(IFDictionaryManifest.filename), options: .atomic)
            print("Generated \(result.manifest.entryCount) entries, \(result.manifest.contentVersion)")
        } else {
            throw IFDictionaryError("arguments", "Usage: dictionary-generator sources | generate SOURCES LEGACY CORRECTIONS OUTPUT")
        }
    }
}
