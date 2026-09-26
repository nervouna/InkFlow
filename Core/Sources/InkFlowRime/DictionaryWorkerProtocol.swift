import InkFlowDomain
import Foundation

package struct IFDictionaryContentIdentity: Codable, Equatable, Sendable {
    package let contentVersion: String
    package let runtimeFingerprint: String
    package init(contentVersion: String, runtimeFingerprint: String) {
        self.contentVersion = contentVersion; self.runtimeFingerprint = runtimeFingerprint
    }

}
package struct IFDictionaryWorkerRequest: Codable, Sendable {
    package let candidate: URL
    package let runtimeFingerprint: String
    package let receipts: [IFDictionarySourceReceipt]
    package let reuseDictionary: Bool
    package let existing: IFDictionaryContentIdentity?
    package init(candidate: URL, runtimeFingerprint: String, receipts: [IFDictionarySourceReceipt], reuseDictionary: Bool, existing: IFDictionaryContentIdentity?) {
        self.candidate = candidate; self.runtimeFingerprint = runtimeFingerprint; self.receipts = receipts; self.reuseDictionary = reuseDictionary; self.existing = existing
    }

}
package struct IFDictionaryWorkerResult: Codable, Sendable {
    package enum Outcome: String, Codable, Sendable { case prepared, contentUnchanged }
    package let outcome: Outcome
    package let manifest: IFDictionaryManifest
    package init(outcome: Outcome, manifest: IFDictionaryManifest) {
        self.outcome = outcome; self.manifest = manifest
    }

}
package struct IFDictionaryWorkerEvent: Codable, Sendable {
    package var progress: IFDictionaryProgress?
    package var result: IFDictionaryWorkerResult?
    package var failure: IFDictionaryUpdateError?
    package init(progress: IFDictionaryProgress? = nil, result: IFDictionaryWorkerResult? = nil, failure: IFDictionaryUpdateError? = nil) {
        self.progress = progress; self.result = result; self.failure = failure
    }

}
