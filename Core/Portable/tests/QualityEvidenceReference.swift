import Foundation
import InkFlowDomain
import InkFlowRime

/// Records what the Swift engine's `qualitySnapshot()` reports for the steps in
/// `fixtures/quality-evidence-cases.json`, as the reference `fixtures/quality-evidence.json` that the
/// Rust engine is compared with. Built and run by `quality-evidence-reference.sh`.
///
/// Arguments: SHARED USER CASES OUTPUT REVISION. SHARED holds the prepared resources.
@main
struct QualityEvidenceReference {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count == 6, "usage: SHARED USER CASES OUTPUT REVISION")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [String: Any]
        try IFEngine.start(shared: args[1], user: args[2])
        defer { IFEngine.stop() }
        let count = spec["candidateCount"] as! Int
        let engine = IFEngine()!
        engine.setConfiguration(candidateCount: count, customPhrases: [], inputPreferences: InputPreferences())
        precondition(engine.configurationError == nil)
        // Seeds are voice corrections, which write the shared English and voice-alias memories.
        for seed in spec["seeds"] as! [[String]] {
            precondition(engine.learnVoiceCorrection(VoiceLearnedCorrection(sourceCode: seed[0], canonicalText: seed[1])),
                         "seed \(seed)")
        }
        var results: [String: Any] = [:]
        for item in spec["cases"] as! [[String: Any]] {
            engine.clear()
            engine.setPrecedingText("")
            var records: [[String: Any]] = []
            for step in item["steps"] as! [[String: Any]] {
                if let text = step["type"] as? String {
                    for code in text.utf16 { precondition(engine.key(Int32(code)), "unhandled \(text)") }
                } else if let key = step["key"] as? Int {
                    for _ in 0..<(step["repeat"] as? Int ?? 1) { _ = engine.key(Int32(key)) }
                } else if let context = step["preceding"] as? String {
                    engine.setPrecedingText(context)
                } else if step["clear"] != nil {
                    engine.clear()
                } else if let text = step["select"] as? String {
                    let index = engine.snapshot().candidates.firstIndex(of: text)
                    precondition(index != nil, "missing \(text)")
                    engine.select(index!)
                } else if let index = step["highlight"] as? Int {
                    engine.highlight(index)
                } else if let delta = step["page"] as? Int {
                    _ = engine.key(delta > 0 ? 0xff56 : 0xff55)
                } else if let phrases = step["phrases"] as? [[String]] {
                    engine.setConfiguration(candidateCount: count,
                        customPhrases: phrases.map { CustomPhrase(id: UUID(), code: $0[0], text: $0[1]) },
                        inputPreferences: InputPreferences())
                    precondition(engine.configurationError == nil)
                } else if let label = step["record"] as? String {
                    records.append(record(engine.qualitySnapshot(), label: label))
                } else {
                    preconditionFailure("unknown step \(step)")
                }
            }
            engine.clear()
            results[item["name"] as! String] = records
        }
        let document: [String: Any] = [
            "recorded": [
                "by": "Core/Portable/quality-evidence-reference.sh",
                "engine": "Swift IFEngine.qualitySnapshot()",
                "revision": args[5],
                "librime": IFEngine.version,
            ],
            "cases": results,
        ]
        let output = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: URL(fileURLWithPath: args[4]))
        print("PASS Swift quality evidence reference: \(results.count) cases")
    }

    static func record(_ snapshot: QualityPageSnapshot, label: String) -> [String: Any] {
        [
            "label": label,
            "rawInput": snapshot.rawInput,
            "caret": snapshot.caret,
            "selectedPrefix": snapshot.selectedPrefix,
            "page": snapshot.page,
            "pageSize": snapshot.pageSize,
            "highlightedDisplayIndex": snapshot.highlightedDisplayIndex,
            "candidates": snapshot.candidates.map { candidate -> [String: Any] in
                [
                    "text": candidate.text,
                    "displayIndex": candidate.displayIndex,
                    "displayRank": candidate.displayRank,
                    "nativeIndex": candidate.nativeIndex,
                    "nativeRank": candidate.nativeRank,
                    "source": candidate.source as Any? ?? NSNull(),
                    "consumedInputStart": candidate.consumedInputStart as Any? ?? NSNull(),
                    "consumedInputEnd": candidate.consumedInputEnd as Any? ?? NSNull(),
                ]
            },
        ]
    }
}
