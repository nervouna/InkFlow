import Foundation
import InkFlowDictionary

// Standalone comparison host. Shipping preparation still uses its existing worker.
private final class Buffer {
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
private struct Failure: Error { let detail: String }
private func copied(_ bytes: IFDBytes) -> Data {
    bytes.len == 0 ? Data() : Data(bytes: bytes.data!, count: bytes.len)
}
private func check(_ result: OpaquePointer) throws {
    let error = copied(ifd_result_error(result))
    if !error.isEmpty { throw Failure(detail: String(decoding: error, as: UTF8.self)) }
}
private func generated(_ args: [String]) throws -> OpaquePointer {
    let catalogData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let catalog = Buffer(catalogData)
    let specs = try JSONSerialization.jsonObject(with: catalogData) as! [[String: Any]]
    let corrections = Buffer(try Data(contentsOf: URL(fileURLWithPath: args[4])))
    var buffers: [Buffer] = []
    var inputs: [IFDInput] = []
    for spec in specs {
        let id = spec["id"] as! String
        let source = spec["group"] as! String == "legacy"
            ? URL(fileURLWithPath: args[3])
            : URL(fileURLWithPath: args[2]).appendingPathComponent(id + ".yaml")
        let receipt: [String: Any] = [
            "id": id, "name": spec["name"]!, "repository": spec["repository"]!,
            "path": spec["path"]!, "commit": spec["pinnedCommit"]!,
            "blobSHA": spec["pinnedBlobSHA"]!, "sha256": spec["pinnedSHA256"]!,
            "byteCount": spec["pinnedByteCount"]!, "recordCount": 0,
        ]
        let receiptBuffer = Buffer(try JSONSerialization.data(withJSONObject: receipt))
        let dataBuffer = Buffer(try Data(contentsOf: source))
        buffers += [receiptBuffer, dataBuffer]
        let input = IFDInput(receipt: receiptBuffer.borrowed, data: dataBuffer.borrowed)
        let validation = ifd_validate(input)!
        defer { ifd_result_free(validation) }
        try check(validation)
        inputs.append(input)
    }
    return withExtendedLifetime((buffers, catalog, corrections)) {
        inputs.withUnsafeBufferPointer {
            ifd_generate(catalog.borrowed, $0.baseAddress, $0.count, corrections.borrowed)!
        }
    }
}
private func spell(_ path: String) throws -> OpaquePointer {
    let buffer = Buffer(try Data(contentsOf: URL(fileURLWithPath: path)))
    return withExtendedLifetime(buffer) { ifd_spelling(buffer.borrowed)! }
}
private func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    let result: OpaquePointer
    let destination: URL
    if args.count == 6, args[0] == "generate" {
        result = try generated(args)
        destination = URL(fileURLWithPath: args[5])
    } else if args.count == 3, args[0] == "spelling" {
        result = try spell(args[1])
        destination = URL(fileURLWithPath: args[2])
    } else {
        throw Failure(detail: "Expected generate CATALOG SOURCES LEGACY CORRECTIONS NEW_OUTPUT or spelling DICTIONARY NEW_OUTPUT")
    }
    // All input buffers have been released before results are inspected or written.
    defer { ifd_result_free(result) }
    try check(result)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw Failure(detail: "Output already exists")
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    do {
        for index in 0..<ifd_result_count(result) {
            let name = String(decoding: copied(ifd_result_name(result, index)), as: UTF8.self)
            try copied(ifd_result_data(result, index)).write(to: destination.appendingPathComponent(name))
        }
    } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
    }
}
do { try run() }
catch {
    FileHandle.standardError.write(Data("Native generator comparison failed: \(error)\n".utf8))
    exit(1)
}
