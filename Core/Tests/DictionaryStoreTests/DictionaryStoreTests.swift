import Foundation
import InkFlowDictionaryTestSupport

@main struct DictionaryStoreTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inkflow-dictionary-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try verifyDictionaryStore(in: root)
        print("PASS independent dictionary store regression")
    }
}
