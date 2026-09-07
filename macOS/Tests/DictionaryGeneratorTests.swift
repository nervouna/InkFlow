import Foundation

@main
struct DictionaryGeneratorTests {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        do { guard try condition() else { fatalError(message) } } catch { fatalError("\(message): \(error)") }
    }
    static func reject(_ code: String, _ action: () throws -> Void) {
        do { try action(); fatalError("Expected \(code)") }
        catch let error as IFDictionaryError { expect(error.code == code, "Expected \(code), got \(error)") }
        catch { fatalError("Unexpected error: \(error)") }
    }
    static func fixture(_ bodies: [String: String] = [:], header: String = "---\nimport_tables: [ignored]\n...\n") -> ([IFDictionaryInput], [IFDictionarySourceSpec]) {
        var inputs = [IFDictionaryInput](), catalog = [IFDictionarySourceSpec]()
        for spec in IFDictionaryCatalog.sources {
            let data = Data((header + (bodies[spec.id] ?? "甲\tjia\t100\n")).utf8)
            let receipt = IFDictionarySourceReceipt(id: spec.id, commit: spec.pinnedCommit, blobSHA: IFDictionaryHash.gitBlob(data),
                sha256: IFDictionaryHash.sha256(data), byteCount: data.count, recordCount: 0)
            inputs.append(IFDictionaryInput(receipt: receipt, data: data))
            catalog.append(IFDictionarySourceSpec(id: spec.id, group: spec.group, name: spec.name, repository: spec.repository,
                branch: spec.branch, path: spec.path, pinnedCommit: receipt.commit, pinnedBlobSHA: receipt.blobSHA,
                pinnedSHA256: receipt.sha256, pinnedByteCount: receipt.byteCount, defaultWeight: spec.defaultWeight))
        }
        return (inputs, catalog)
    }
    static func generate(_ bodies: [String: String] = [:], corrections: String = "") throws -> IFDictionaryGeneration {
        let (inputs, catalog) = fixture(bodies)
        return try IFDictionaryGenerator.generate(inputs: inputs, corrections: Data(corrections.utf8), catalog: catalog)
    }
    static func text(_ result: IFDictionaryGeneration) -> String { String(decoding: result.dictionary, as: UTF8.self) }
    static func main() throws {
        expect(IFDictionaryHash.gitBlob(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a", "Git blob includes byte-count header")
        expect(try IFDictionaryGenerator.normalizedReading("  LÜ\u{a0}SE  ") == "lv se", "Pinyin whitespace, case, ü normalization")
        expect(try IFDictionaryGenerator.normalizedReading("LU\u{308} SE") == "lv se", "Decomposed ü normalizes")
        let union = try generate([
            "frost-8105": "甲\tjia\t100\n绿\tlü\t0\n行\txing\t22\n",
            "frost-base": "甲\tJIA\t900\n行\thang\t33\n〇\tling\t0\n",
            "frost-idiom": "床前明月光\tchuang qian ming yue guang\t0\n",
            "ice-base": "甲\tjia\t10\n绿\tLV\t1000\n新增\txin zeng\t2\n零词\tling ci\t0\n",
            "legacy": "甲\tjia\t200\n新增\txin zeng\t10000\n旧词\tjiu ci\t1\n"
        ])
        let output = text(union)
        for row in ["甲\tjia\t100\n", "绿\tlv\t0\n", "行\txing\t22\n", "行\thang\t33\n", "〇\tling\t0\n",
                    "床前明月光\tchuang qian ming yue guang\t0\n", "新增\txin zeng\t20\n", "零词\tling ci\t0\n", "旧词\tjiu ci\t1\n"] {
            expect(output.contains(row), "Missing union rule: \(row)")
        }
        expect(union.manifest.entryCount == 9, "Deduplicate by term + normalized reading")
        let specialty = try generate([
            "frost-computer": "甲\tjia\t9000\n新增\txin zeng\t9000\n专业词\tzhuan ye ci\t3",
            "frost-exthot": "专业词\tzhuan ye ci\t9000\n网络新词\twang luo xin ci\t2\n",
            "selected-computer": "新增\txin zeng\n旧词\tjiu ci\n二列词\ter lie ci\n串行打印机\tchuan hang da yin ji\n",
            "ice-base": "甲\tjia\t10\n新增\txin zeng\t2\n",
            "legacy": "甲\tjia\t200\n旧词\tjiu ci\t4\n"
        ])
        for row in ["甲\tjia\t100\n", "新增\txin zeng\t20\n", "旧词\tjiu ci\t2\n", "专业词\tzhuan ye ci\t3\n",
                    "网络新词\twang luo xin ci\t2\n", "二列词\ter lie ci\t1\n", "串行打印机\tchuan xing da yin ji\t1\n"] {
            expect(text(specialty).contains(row), "Specialty fill-only/source weight/correction: \(row)")
        }
        expect(!text(specialty).contains("串行打印机\tchuan hang"), "Do not retain known wrong reading")
        expect(specialty.manifest.calibrations.map(\.pairCount) == [1, 1], "Specialty overlaps cannot affect calibration")
        reject("source-format") { _ = try generate(["frost-computer": "专业词\tzhuan ye ci\n"]) }
        reject("source-format") { _ = try generate(["selected-computer": "专业词\tzhuan ye ci\t\n"]) }
        expect(!output.contains("import_tables"), "Ignore remote imports")
        let roundtrip = try JSONDecoder().decode(IFDictionaryManifest.self, from: union.manifest.encoded())
        expect(roundtrip == union.manifest, "Stable Codable metadata")
        expect(roundtrip.sources[0].repository == "gaboolic/rime-frost" && roundtrip.sources[0].path == "cn_dicts/8105.dict.yaml",
               "Manifest source provenance is self-contained")
        let repeated = try generate()
        let repeatedAgain = try generate()
        expect(repeated.dictionary == repeatedAgain.dictionary, "Deterministic dictionary bytes")
        expect(try repeated.manifest.encoded() == repeatedAgain.manifest.encoded(), "Deterministic metadata bytes")
        let sameContent = try generate(["frost-base": "# upstream comment only\n甲\tjia\t100\n"])
        expect(sameContent.manifest.contentVersion == repeated.manifest.contentVersion, "Source-only changes do not change content version")
        expect(sameContent.manifest.sources != repeated.manifest.sources, "Provenance still reflects source-only changes")
        let corrected = try generate(corrections: "甲\tJIA\t0\tRegression override\n新词\txin ci\t7\tExplicit addition\n")
        expect(text(corrected).contains("甲\tjia\t0\n") && text(corrected).contains("新词\txin ci\t7\n"), "Corrections apply last")
        expect(corrected.manifest.contentVersion != repeated.manifest.contentVersion, "Weight change changes content version")
        let evenMedian = try generate([
            "frost-8105": "甲\tjia\t9\n乙\tyi\t1\n",
            "ice-base": "甲\tjia\t1\n乙\tyi\t1\n新增\txin zeng\t5\n"
        ])
        expect(abs(evenMedian.manifest.calibrations[0].overallMultiplier - 3) < 1e-10, "Median in log space")
        expect(text(evenMedian).contains("新增\txin zeng\t15\n"), "Round calibrated weight")
        var frost = "甲\tjia\t100\n", ice = "甲\tjia\t50\n"
        for index in 0..<100 { frost += "词\(index)\tci yu\t100\n"; ice += "词\(index)\tci yu\t10\n" }
        ice += "稀\txi\t1\n二词\ter ci\t1\n"
        let buckets = try generate(["frost-8105": frost, "ice-base": ice]).manifest.calibrations[0]
        expect(buckets.buckets[1].pairCount == 100 && !buckets.buckets[1].usedOverall, "100 pairs enables bucket calibration")
        expect(buckets.buckets[0].pairCount == 1 && buckets.buckets[0].usedOverall, "Small bucket falls back to overall")
        expect(abs(buckets.buckets[0].multiplier - 10) < 1e-10, "Fallback uses all groups")
        reject("calibration-empty") { _ = try generate(["ice-base": "独\tdu\t10\n", "ice-ext": "独\tdu\t10\n"]) }
        for bad in ["甲\tjia\t-1\n", "甲\tjia\t1%\n", "甲\tjia\t2147483648\n", "甲\tjia\n", "english\tying yu\t1\n"] {
            reject("source-format") { _ = try generate(["frost-8105": bad]) }
        }
        reject("invalid-reading") { _ = try generate(["frost-8105": "甲\tjiǎ\t1\n"]) }
        let verifiedNoNewline = try generate(["frost-8105": "甲\tjia\t1"])
        expect(text(verifiedNoNewline).contains("甲\tjia\t1\n"), "Verified complete bytes need no final newline")
        reject("correction-duplicate") { _ = try generate(corrections: "甲\tjia\t1\tone\n甲\tJIA\t2\ttwo\n") }
        reject("correction-format") { _ = try generate(corrections: "甲\tjia\t1\t\n") }
        let (inputs, catalog) = fixture()
        reject("source-set") { _ = try IFDictionaryGenerator.generate(inputs: Array(inputs.dropLast()), catalog: catalog) }
        reject("legacy-changed") { _ = try IFDictionaryGenerator.generate(inputs: inputs) }
        var moved = inputs
        let original = inputs[0].receipt
        moved[0] = IFDictionaryInput(receipt: IFDictionarySourceReceipt(id: original.id, commit: original.commit,
            blobSHA: original.blobSHA, sha256: original.sha256, byteCount: original.byteCount, recordCount: 0,
            repository: "other/repository"), data: inputs[0].data)
        reject("source-location") { _ = try IFDictionaryGenerator.generate(inputs: moved, catalog: catalog) }
        var badHash = inputs
        badHash[0] = IFDictionaryInput(receipt: inputs[0].receipt, data: Data(repeating: 32, count: inputs[0].data.count))
        reject("source-checksum") { _ = try IFDictionaryGenerator.generate(inputs: badHash, catalog: catalog) }
        var truncated = inputs
        truncated[0] = IFDictionaryInput(receipt: inputs[0].receipt, data: inputs[0].data.dropLast())
        reject("source-size") { _ = try IFDictionaryGenerator.generate(inputs: truncated, catalog: catalog) }
        let missingHeader = fixture(header: "import_tables: [ignored]\n")
        reject("source-format") { _ = try IFDictionaryGenerator.generate(inputs: missingHeader.0, catalog: missingHeader.1) }
        if CommandLine.arguments.count == 4 {
            try actualSources(directory: CommandLine.arguments[1], legacy: CommandLine.arguments[2], output: CommandLine.arguments[3])
        }
        print("PASS dictionary generator: normalized union, precedence, multiple readings, zero weights, log median, bucket/fallback, corrections, rejection, deterministic content/provenance")
    }

    static func actualSources(directory: String, legacy: String, output: String) throws {
        let sources = URL(fileURLWithPath: directory), destination = URL(fileURLWithPath: output)
        let inputs = try IFDictionaryCatalog.sources.map { spec in
            IFDictionaryInput(receipt: spec.pinnedReceipt, data: try Data(contentsOf: spec.isUpdatable
                ? sources.appendingPathComponent(spec.id + ".yaml") : URL(fileURLWithPath: legacy)))
        }
        let corrections = try Data(contentsOf: destination.appendingPathComponent(IFDictionaryCatalog.correctionsFilename))
        let result = try IFDictionaryGenerator.generate(inputs: inputs, corrections: corrections)
        expect(text(result).contains("命令行用户交互\tming ling hang yong hu jiao hu\t1\n"),
               "Command-line uses hang, independently of the curated input table")
        expect(!text(result).contains("命令行用户交互\tming ling xing"), "Do not confuse command-line with serial execution")
        expect(result.manifest.entryCount == IFDictionaryCatalog.initialEntryCount, "Initial pinned source coverage")
        expect(try Data(contentsOf: destination.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename)) == result.dictionary,
               "Build CLI and shared runtime module generate identical bytes")
        expect(try Data(contentsOf: destination.appendingPathComponent(IFDictionaryManifest.filename)) == result.manifest.encoded(),
               "Build CLI and shared runtime module generate identical metadata")
        expect(text(result).contains("歇后语\txie hou yu\t72\n"), "Preserve Frost 歇后语 weight")
        expect(text(result).contains("肃然起敬\tsu ran qi jing\t337\n"), "Preserve Frost 肃然起敬 weight")
        print("PASS pinned corpus: \(result.manifest.entryCount) records, CLI/runtime byte parity, required term weights")
    }
}
