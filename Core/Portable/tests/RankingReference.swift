import Foundation

@main
struct RankingReference {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count == 3)
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [[String: Any]]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pinyin_simp.context.bin")
        var results: [String: Any] = [:]
        for item in cases {
            try IFContextRanker.buildIndex(dictionary: Data((item["dictionary"] as! String).utf8)).write(to: file)
            let ranker = try IFContextRanker(index: file.path)
            let candidates = item["candidates"] as! [String]
            let metadata = (item["metadata"] as? String).flatMap {
                IFContextRanker.parseMetadata($0, offset: item["offset"] as! Int,
                    count: candidates.count, inputLength: item["inputLength"] as! Int)
            }
            let parsed = metadata.map { rows in rows.map { row in
                "\(row.coverage.lowerBound),\(row.coverage.upperBound),\(row.candidateClass.rawValue),\(row.exact ? 1 : 0),\(row.personalBucket),\(row.source.rawValue)"
            }}
            results[item["name"] as! String] = [
                "parsed": parsed as Any? ?? NSNull(),
                "order": ranker.order(candidates, precedingText: item["context"] as! String, metadata: metadata)
            ]
        }
        let output = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: URL(fileURLWithPath: args[2]))
        print("PASS Swift ranking reference: \(cases.count) cases")
    }
}
