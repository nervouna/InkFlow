import Foundation
@testable import InkFlowDomain

private func check(_ condition: @autoclosure () -> Bool, _ message: String = "") { precondition(condition(), message) }

@MainActor
package func verifyRankingRules(in directory: URL) throws {
        let url = directory.appendingPathComponent("ranking-fixture.yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "午餐\twu can\t100\n午参\twu can\t100\n午惨\twu can\t50\n准备午参\tzhun bei wu can\t1\n迷你\tmi ni\t70\n".write(to: url, atomically: true, encoding: .utf8)
        let ranker = try IFContextRanker(dictionary: url.path)
        func row(_ coverage: Range<Int> = 0..<3,
                 _ candidateClass: IFCandidateRankingMetadata.CandidateClass = .nonASCII,
                 exact: Bool = true, personal: Int = 0,
                 source: IFCandidateRankingMetadata.Source = .native) -> IFCandidateRankingMetadata {
            .init(coverage: coverage, candidateClass: candidateClass, exact: exact,
                  personalBucket: personal, source: source)
        }
        let han = [row(), row(), row()]
        check(ranker.order(["惨", "餐", "参"], precedingText: "准备午", metadata: han) == [2, 1, 0], "Longer crossing phrases precede frequency")
        check(ranker.order(["惨", "餐", "参"], precedingText: "午", metadata: han) == [1, 2, 0], "Frequency then stable original order")
        let conflict = [row(), row(0..<3, .ascii, source: .english), row(), row()]
        check(ranker.order(["惨", "can", "餐", "你"], precedingText: "午", metadata: conflict) == [2, 1, 0, 3],
              "Context reorders eligible Han candidates only within their original slots")
        check(ranker.order(["你好", "你"], precedingText: "迷", metadata: [row(0..<5), row(0..<5)]) == [0, 1], "Unequal-length choices remain in the native relative order")
        let invalidMetadata: [[IFCandidateRankingMetadata]?] = [nil, [], [row()],
            [row(), row(0..<1)], [row(), row(1..<4)]]
        for metadata in invalidMetadata {
            check(ranker.order(["惨", "餐"], precedingText: "午", metadata: metadata) == [0, 1],
                  "Unknown or different native spans must not permit context promotion")
        }
        check(ranker.order(["惨", "餐", "参"], precedingText: "午", metadata: [row(), row(0..<1), row()]) == [2, 1, 0],
              "An ineligible partial candidate retains its slot while equal-span alternatives rank")
        let parsed = IFContextRanker.parseMetadata("9,3;0,4,n,1,0,n;0,4,a,1,2,e;0,1,m,1,1,m",
                                                   offset: 9, count: 3, inputLength: 4)
        check(parsed == [row(0..<4), row(0..<4, .ascii, personal: 2, source: .english),
                         row(0..<1, .mixed, personal: 1, source: .mixed)])
        for invalid in ["", "0,3;0,4,n,1,0,n;0,4,a,1,2,e;0,1,m,1,1,m",
                        "9,3;0,4,n,1,0,n;0,4,a,1,2,e",
                        "9,3;0,4,n,1,0,n;0,4,a,1,2,e;0,1,m,1,1,m;0,1,n,1,0,n",
                        "9,3;0,5,n,1,0,n;0,4,a,1,2,e;0,1,m,1,1,m",
                        "9,3;0,4,n,1,0,n;2,1,a,1,2,e;0,1,m,1,1,m",
                        "9,3;0,4,n,1,0,n;0,4,x,1,2,e;0,1,m,1,1,m",
                        "9,3;0,4,n,1,0,n;0,4,a,2,2,e;0,1,m,1,1,m",
                        "9,3;0,4,n,1,0,n;0,4,a,1,4,e;0,1,m,1,1,m",
                        "9,3;0,4,n,1,0,n;0,4,a,0,2,e;0,1,m,1,1,m"] {
            check(IFContextRanker.parseMetadata(invalid, offset: 9, count: 3, inputLength: 4) == nil,
                  "Malformed, stale-page or truncated span metadata must fail closed")
        }
        let evidence = [row(0..<5), row(0..<5, .ascii, personal: 1, source: .english),
                        row(0..<5, .ascii, exact: false, source: .english), row(0..<5)]
        check(ranker.order(["从哦的新", "Codex", "Codex CLI", "才"], precedingText: "日常", metadata: evidence) == [0, 1, 3, 2],
              "Neutral ordering keeps one Chinese candidate first, then exact English before completion")
        check(ranker.order(["从哦的新", "Codex", "Codex CLI", "才"], precedingText: "正在使用 Swift ", metadata: evidence) == [1, 0, 3, 2],
              "Bounded technical context plus personal exact evidence may promote English")
        let strengths = [row(0..<5), row(0..<5, .ascii, personal: 1, source: .english),
                         row(0..<5, .ascii, personal: 3, source: .english)]
        check(ranker.order(["从哦的新", "Codex", "SwiftUI"], precedingText: "正在使用 CLI ", metadata: strengths) == [2, 1, 0],
              "Personal commit evidence is bounded and stronger buckets rank first")
        for bucket in 1...3 {
            check(ranker.order(["是一台", "是以他I"], precedingText: "API 已经",
                               metadata: [row(0..<8), row(0..<8, .mixed, personal: bucket, source: .mixed)]) == [0, 1],
                  "Learning an embedded English token does not certify whole-sentence intent in technical context")
        }
        let custom = [row(0..<5), row(0..<5, .nonASCII, source: .custom),
                      row(0..<5, .ascii, personal: 3, source: .english)]
        check(ranker.order(["从哦的新", "自定义", "Codex"], precedingText: "正在使用 CLI ", metadata: custom) == [1, 2, 0],
              "Explicit custom source remains ahead of personal technical evidence")
        check(ranker.order(["从哦的新", "Codex"], precedingText: "正在使用 CLI ",
                           metadata: [row(0..<5), row(0..<5, .nonASCII, personal: 1, source: .english)]) == [0, 1],
              "Inconsistent candidate class metadata fails closed to native order")
        print("PASS context ranking rules: equal native spans, unknown metadata fallback, strict page identity, longer match, frequency, stable ties, fixed ineligible slots")
    }
