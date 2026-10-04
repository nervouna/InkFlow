import Foundation
import InkFlowDictionary

// Foreign input buffers stay alive through each synchronous preparation call.
private final class DictionaryBuffer {
    private let pointer: UnsafeMutablePointer<UInt8>
    private let count: Int
    init(_ data: Data) {
        count = data.count
        pointer = .allocate(capacity: max(1, count))
        data.copyBytes(to: pointer, count: count)
    }
    var borrowed: IFDBytes { .init(data: UnsafePointer(pointer), len: count) }
    deinit { pointer.deallocate() }
}

private enum DictionaryNative {
    private struct Failure: Decodable {
        let code: String
        let source: String?
        let line: Int?
    }
    static func copy(_ bytes: IFDBytes) -> Data {
        bytes.len == 0 ? Data() : Data(bytes: bytes.data!, count: bytes.len)
    }
    static func consume(_ result: OpaquePointer) throws -> [String: Data] {
        defer { ifd_result_free(result) }
        let error = copy(ifd_result_error(result))
        if !error.isEmpty {
            let failure = try JSONDecoder().decode(Failure.self, from: error)
            throw IFDictionaryError(failure.code, source: failure.source, line: failure.line,
                                    "Dictionary input validation or generation failed")
        }
        var files = [String: Data]()
        for index in 0..<ifd_result_count(result) {
            let name = String(decoding: copy(ifd_result_name(result, index)), as: UTF8.self)
            files[name] = copy(ifd_result_data(result, index))
        }
        return files
    }
}

/// Calls the shared Rust generator in-process, outside interactive input handling.
package enum IFDictionaryGenerator {
    package static func catalog() -> [IFDictionarySourceSpec] {
        // This immutable JSON is compiled into the same verified Rust library.
        try! JSONDecoder().decode([IFDictionarySourceSpec].self, from: DictionaryNative.copy(ifd_catalog()))
    }

    package static func generate(inputs: [IFDictionaryInput], corrections: Data = Data(),
                         catalog: [IFDictionarySourceSpec] = IFDictionaryCatalog.sources) throws -> IFDictionaryGeneration {
        let encoder = JSONEncoder()
        let catalogBuffer = DictionaryBuffer(try encoder.encode(catalog))
        let correctionBuffer = DictionaryBuffer(corrections)
        var buffers = [DictionaryBuffer]()
        var raw = [IFDInput]()
        for input in inputs {
            let receipt = DictionaryBuffer(try encoder.encode(input.receipt))
            let data = DictionaryBuffer(input.data)
            buffers += [receipt, data]
            raw.append(.init(receipt: receipt.borrowed, data: data.borrowed))
        }
        let result = withExtendedLifetime((buffers, catalogBuffer, correctionBuffer)) {
            raw.withUnsafeBufferPointer {
                ifd_generate(catalogBuffer.borrowed, $0.baseAddress, $0.count, correctionBuffer.borrowed)!
            }
        }
        let files = try DictionaryNative.consume(result)
        guard let dictionary = files[IFDictionaryCatalog.dictionaryFilename],
              let metadata = files[IFDictionaryManifest.filename] else {
            throw IFDictionaryError("bridge-output", "Missing generated dictionary or manifest")
        }
        let manifest = try JSONDecoder().decode(IFDictionaryManifest.self, from: metadata)
        return IFDictionaryGeneration(dictionary: dictionary, manifest: manifest)
    }

    package static func validate(_ input: IFDictionaryInput) throws {
        let receipt = DictionaryBuffer(try JSONEncoder().encode(input.receipt))
        let data = DictionaryBuffer(input.data)
        let result = withExtendedLifetime((receipt, data)) {
            ifd_validate(.init(receipt: receipt.borrowed, data: data.borrowed))!
        }
        _ = try DictionaryNative.consume(result)
    }
}

package enum IFSpellingGenerator {
    package static func generate(dictionary: Data) throws -> [String: Data] {
        let buffer = DictionaryBuffer(dictionary)
        let result = withExtendedLifetime(buffer) { ifd_spelling(buffer.borrowed)! }
        return try DictionaryNative.consume(result)
    }
    package static func write(dictionary: Data, to directory: URL) throws {
        let schemas = try generate(dictionary: dictionary)
        for name in schemas.keys.sorted() {
            try schemas[name]!.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }
}
