import Foundation
import InkFlowAppleEngine
@preconcurrency import InputMethodKit

@MainActor
final class MacEngineHost {
    static let candidateIndexAttribute = NSAttributedString.Key(
        "io.inkflow.local.candidate-index"
    )
    static let shared = MacEngineHost()

    private let runtimeResult: Result<EngineRuntime, Error>
    private(set) var candidates: IMKCandidates?
    private var candidateObjects: [NSAttributedString] = []
    private var candidateIndices: [Int: Int] = [:]
    private var ambiguousCandidateIdentifiers: Set<Int> = []

    private init() {
        runtimeResult = Result {
            guard let resourceURL = Bundle.main.resourceURL else {
                throw EngineError.runtimeUnavailable
            }
            let schemaURL = resourceURL.appendingPathComponent(
                "Schema",
                isDirectory: true
            )
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("InkFlow/InputMethod", isDirectory: true)
            let cache = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("InkFlow/InputMethod", isDirectory: true)
            return try EngineRuntime(configuration: EngineConfiguration(
                sharedDataURL: schemaURL,
                userDataURL: support.appendingPathComponent("User", isDirectory: true),
                prebuiltDataURL: schemaURL,
                stagingDataURL: cache.appendingPathComponent("Staging", isDirectory: true),
                distributionCodeName: "inkflow-macos",
                applicationName: "rime.inkflow.macos"
            ))
        }
    }

    func configure(server: IMKServer) {
        candidates = IMKCandidates(
            server: server,
            panelType: kIMKSingleColumnScrollingCandidatePanel
        )
        candidates?.setDismissesAutomatically(false)
    }

    func makeSession() throws -> EngineSession {
        try runtimeResult.get().makeSession(schemaID: "inkflow")
    }

    func presentCandidates(_ values: [String]) {
        candidateObjects = values.enumerated().map { index, value in
            NSAttributedString(
                string: value,
                attributes: [Self.candidateIndexAttribute: index]
            )
        }
        candidates?.setCandidateData(candidateObjects)
        candidateIndices.removeAll(keepingCapacity: true)
        ambiguousCandidateIdentifiers.removeAll(keepingCapacity: true)
        if let candidates {
            for (index, value) in candidateObjects.enumerated() {
                let identifier = candidates.candidateStringIdentifier(value)
                if ambiguousCandidateIdentifiers.contains(identifier) {
                    continue
                } else if candidateIndices[identifier] == nil {
                    candidateIndices[identifier] = index
                } else {
                    candidateIndices.removeValue(forKey: identifier)
                    ambiguousCandidateIdentifiers.insert(identifier)
                }
            }
        }
        if values.isEmpty {
            candidates?.hide()
        } else {
            candidates?.show(kIMKLocateCandidatesBelowHint)
        }
    }

    func hideCandidates() {
        candidates?.hide()
    }

    func index(of selected: NSAttributedString) -> Int? {
        if selected.length > 0,
           let index = selected.attribute(
               Self.candidateIndexAttribute,
               at: 0,
               effectiveRange: nil
           ) {
            if let index = index as? Int { return index }
            if let index = index as? NSNumber { return index.intValue }
        }
        guard let candidates else { return nil }
        let identifier = candidates.candidateStringIdentifier(selected)
        return candidateIndices[identifier]
    }
}
