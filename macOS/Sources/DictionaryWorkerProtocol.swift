import Foundation

struct IFDictionaryContentIdentity: Codable, Equatable, Sendable {
    let contentVersion: String
    let runtimeFingerprint: String
}
struct IFDictionaryWorkerRequest: Codable, Sendable {
    let candidate: URL
    let runtimeFingerprint: String
    let receipts: [IFDictionarySourceReceipt]
    let reuseDictionary: Bool
    let existing: IFDictionaryContentIdentity?
}
struct IFDictionaryWorkerResult: Codable, Sendable {
    enum Outcome: String, Codable, Sendable { case prepared, contentUnchanged }
    let outcome: Outcome
    let manifest: IFDictionaryManifest
}
struct IFDictionaryWorkerEvent: Codable, Sendable {
    var progress: IFDictionaryProgress?
    var result: IFDictionaryWorkerResult?
    var failure: IFDictionaryUpdateError?
}

extension IFDictionaryRuntime {
    static func bundled(helper: URL) -> Self {
        let contents = helper.deletingLastPathComponent().deletingLastPathComponent()
        return .init(resources: contents.appendingPathComponent("Resources/Rime"), helper: helper,
                     libraries: [contents.appendingPathComponent("Frameworks/librime.1.dylib"),
                                 contents.appendingPathComponent("Frameworks/rime-plugins/librime-lua.dylib")])
    }
}
