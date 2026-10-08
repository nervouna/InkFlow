@testable import InkFlowRime
@testable import InkFlowDomain
import Foundation

@main
struct VoiceLexiconTests {
    static func main() throws {
        let snapshot = VoiceLexiconSnapshot(generation: 3, revision: 4, availability: .available,
            entries: [.init(text: "张玮", code: "zhang wei ", commits: 3),
                      .init(text: "墨流", code: "mo liu ", commits: 1)])
        func select(_ groups: [[String]], _ view: VoiceLexiconSnapshot = snapshot, prefix: String = "") -> String {
            VoiceAlternativeReranker.select(groups, snapshot: view, fixedPrefix: prefix)
        }
        precondition(select([["张"], ["伟", "玮"]]) == "张玮", "Learned words span adjacent ranges")
        precondition(select([["伟", "玮"]], prefix: "张") == "玮", "Fixed prior final text influences current range only")
        precondition(select([["张"], ["伟", "玮"]], .unknown()) == "张伟", "Unknown evidence keeps primary")
        precondition(select([["张伟", "张玮"]], .init(generation: 0, revision: 0, availability: .available, entries: [])) == "张伟")
        precondition(select([["张伟", "张明"]]) == "张伟", "Different pronunciation is ineligible")
        precondition(select([["张伟使用 Swift", "张玮使用 Python"]]) == "张伟使用 Swift", "Latin transcript cannot change")
        precondition(select([["张伟。", "张玮！"]]) == "张伟。", "Punctuation is preserved")
        precondition(select([["张伟", "张炜"]]) == "张伟", "No evidence preserves Apple order")
        precondition(select([["星木海", "星慕海"]]) == "星木海", "Missing ASR novel-word alternative cannot be invented")
        // A conservative spelling-description heuristic deliberately forgoes reranking.
        // It does not claim to infer intended spelling from arbitrary language.
        precondition(select([["张伟，伟大的伟", "张玮，玮大的玮"]]) == "张伟，伟大的伟")
        precondition(select([["张伟，伟岸的伟", "张玮，玮岸的玮"]]) == "张伟，伟岸的伟")
        precondition(select([["张伟的朋友", "张玮的朋友"]]) == "张玮的朋友", "Ordinary possessive is not spelling guidance")
        let custom = try CustomPhrase.validated(code: "zw", text: "张伟")
        precondition(select([["张玮", "张伟"]], snapshot.includingCustomPhrases([custom])) == "张伟", "Explicit phrases outrank learned frequency")
        precondition(select([["张玮", "张伟"]], VoiceLexiconSnapshot.unknown().includingCustomPhrases([custom])) == "张伟")
        let tied = VoiceLexiconSnapshot(generation: 0, revision: 0, availability: .available, entries: [
            .init(text: "张玮", code: "zhang wei ", commits: 1), .init(text: "张伟", code: "zhang wei ", commits: 1)])
        precondition(select([["张伟", "张玮"]], tied) == "张伟")
        let duplicates = Array(repeating: snapshot.entries[0], count: 1000)
        precondition(VoiceLexiconSnapshot(generation: 0, revision: 0, availability: .available, entries: duplicates).entries.count == 1)
        let many = (0..<9000).map { VoiceLexiconSnapshot.Entry(text: "测试\($0)", code: "ce shi ", commits: 1) }
        let capped = VoiceLexiconSnapshot(generation: 0, revision: 0, availability: .available, entries: many)
        precondition(capped.entries.count == 8192)
        let huge = many.map { VoiceLexiconSnapshot.Entry(text: $0.text, code: String(repeating: "a", count: 10_000), commits: 1) }
        let byteCapped = VoiceLexiconSnapshot(generation: 0, revision: 0, availability: .available, entries: huge)
        precondition(byteCapped.entries.reduce(0) { $0 + $1.text.utf8.count + $1.code.utf8.count + 32 } <= VoiceLexiconSnapshot.byteLimit)
        precondition(VoiceLexiconSnapshot(status: "unknown", rows: "", generation: 0, revision: 0).availability == .unknown)
        precondition(VoiceLexiconSnapshot(status: "ok", rows: "", generation: 0, revision: 0).availability == .available)
        precondition(VoiceLexiconSnapshot(status: "ok", rows: String(repeating: "a", count: 524_289), generation: 0, revision: 0).availability == .unknown)
        let groups = Array(repeating: ["伟", "玮", "炜", "苇", "委", "尾", "纬", "伪"], count: 64)
        precondition(select(groups) == String(repeating: "伟", count: 64), "Bounded alternative explosion retains stable ties")
        precondition(select(Array(repeating: ["张伟", "张玮"], count: 65)) == String(repeating: "张伟", count: 65))
        let aliases = VoiceAliasSnapshot(status: "ok", rows: "codux\tCodex\t2\nswiftui\tSwiftUI\t1\n",
                                         generation: 2, revision: 3)
        precondition(VoiceAliasRewriter.apply("用 codux，配合 swiftui。", snapshot: aliases) == "用 Codex，配合 SwiftUI。")
        precondition(VoiceAliasRewriter.apply("mycodux 和 coduxx 不替换", snapshot: aliases) == "mycodux 和 coduxx 不替换",
                     "Voice aliases require exact ASCII token boundaries")
        precondition(VoiceAliasRewriter.apply("codux", snapshot: .unknown()) == "codux",
                     "Unknown alias evidence preserves finalized ASR")
        let ambiguous = VoiceAliasSnapshot(status: "ok", rows: "codux\tCodex\t1\ncodux\tCODEX\t1\n",
                                           generation: 2, revision: 4)
        precondition(VoiceAliasRewriter.apply("codux", snapshot: ambiguous) == "codux",
                     "Ambiguous exact aliases fail closed")
        let oversized = Array(repeating: "aa\tWord\t1", count: 513).joined(separator: "\n") + "\n"
        precondition(VoiceAliasSnapshot(status: "ok", rows: oversized, generation: 2, revision: 5).availability == .unknown,
                     "Oversized alias evidence fails closed")
        print("PASS voice lexicon: learned alternatives, fixed prefix, explicit phrases, spelling controls, stable ties and bounds")
    }
}
