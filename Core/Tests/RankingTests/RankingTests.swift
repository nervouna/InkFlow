import Foundation
import InkFlowRankingTestSupport

@main struct RankingTests {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inkflow-ranking-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try verifyRankingRules(in: directory)
    }
}
