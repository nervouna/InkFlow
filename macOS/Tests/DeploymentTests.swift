import AppKit

@main
struct DeploymentTests {
    @MainActor static func main() throws {
        check(CommandLine.arguments.count == 3)
        let files = FileManager.default
        let fixture = files.temporaryDirectory.appendingPathComponent("inkflow-deployment-\(UUID().uuidString)")
        defer { try? files.removeItem(at: fixture) }
        try files.createDirectory(at: fixture, withIntermediateDirectories: true)
        let original = fixture.appendingPathComponent("original")
        let admitted = fixture.appendingPathComponent("admitted")
        let user = fixture.appendingPathComponent("user")
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        try files.copyItem(at: source, to: original)
        try files.copyItem(at: source, to: admitted)
        try files.removeItem(at: original.appendingPathComponent("easy_en.dict.yaml"))
        try files.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]),
                           to: original.appendingPathComponent("easy_en.dict.yaml"))

        try IFEngine.start(shared: original.path, user: user.path)
        verifyEnglish(expectsOriginal: true)
        IFEngine.stop()
        let userDictionary = user.appendingPathComponent("pinyin_simp.userdb")
        check(files.fileExists(atPath: userDictionary.appendingPathComponent("CURRENT").path))
        let sentinel = userDictionary.appendingPathComponent("admission-upgrade-sentinel")
        let sentinelData = Data("preserve the existing Chinese user dictionary".utf8)
        try sentinelData.write(to: sentinel)

        // Reproduce a bundle built before the old engine's latest deployment.
        // Preserve user.yaml's last_build_time while making all YAML mtimes older.
        let oldDate = Date(timeIntervalSince1970: 946684800)
        for directory in [admitted, user] {
            let entries = files.enumerator(at: directory, includingPropertiesForKeys: nil)!
            for case let file as URL in entries where file.pathExtension == "yaml" {
                try files.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
            }
            try files.setAttributes([.modificationDate: oldDate], ofItemAtPath: directory.path)
        }
        try IFEngine.start(shared: admitted.path, user: user.path)
        verifyEnglish(expectsOriginal: false)
        IFEngine.stop()
        let upgradedSentinel = try Data(contentsOf: sentinel)
        check(upgradedSentinel == sentinelData, "Upgrade preserves Chinese user dictionary data")

        let tables = ["easy_en", "inkflow_mixed", "pinyin_simp"].map {
            user.appendingPathComponent("build/\($0).table.bin")
        }
        let before = try tables.map { try Data(contentsOf: $0) }
        let dates = try tables.map { try files.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        let restartStarted = Date()
        try IFEngine.start(shared: admitted.path, user: user.path)
        print("TRACE unchanged deployment startup: \(Int(Date().timeIntervalSince(restartStarted) * 1000)) ms")
        verifyEnglish(expectsOriginal: false)
        IFEngine.stop()
        for (index, table) in tables.enumerated() {
            let data = try Data(contentsOf: table)
            let date = try files.attributesOfItem(atPath: table.path)[.modificationDate] as? Date
            check(data == before[index], "Unchanged restart retains \(table.lastPathComponent)")
            check(date == dates[index],
                  "Unchanged restart must not rewrite \(table.lastPathComponent)")
        }
        let restartedSentinel = try Data(contentsOf: sentinel)
        check(restartedSentinel == sentinelData, "Restart preserves Chinese user dictionary data")
        print("PASS deployment: old full English cache replaced despite older resource timestamps; unchanged tables reused; Chinese user-dictionary sentinel retained")
    }

    @MainActor static func verifyEnglish(expectsOriginal: Bool) {
        let engine = IFEngine()!
        type(engine, "women")
        let candidates = engine.snapshot().candidates
        check(candidates.first == "我们", "Chinese remains first during dictionary upgrade")
        let rejected = Set(["WOMENS", "womenfolk"])
        check(expectsOriginal ? !rejected.isDisjoint(with: candidates) : rejected.isDisjoint(with: candidates),
              "Expected \(expectsOriginal ? "original" : "admitted") English after deployment: \(candidates)")
        check(candidates.contains("women"), "Common English remains admitted with measured frequency")
        print("TRACE deployment \(expectsOriginal ? "original" : "admitted") women => \(candidates)")
        engine.clear(); type(engine, "computer")
        check(engine.snapshot().candidates.contains("computer"), "Admitted English survives deployment")
        engine.clear()
    }
}
