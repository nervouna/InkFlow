import Foundation

@main
struct AIPronunciationTests {
    static func fixture(dictionaryText: String) -> AIPronunciation {
        var phrases: [String: Set<String>] = [:], characters: [Character: Set<String>] = [:]
        for line in dictionaryText.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            let text = String(fields[0]), code = String(fields[1])
            phrases[text, default: []].insert(code)
            for (character, syllable) in zip(text, code.split(separator: " ")) {
                characters[character, default: []].insert(String(syllable))
            }
        }
        return AIPronunciation(phrases: phrases, characters: characters)
    }
    static func main() throws {

        let resolver = fixture(dictionaryText: """
        你\tni\t1
        好\thao\t1
        星\txing\t1
        墨\tmo\t1
        量\tliang\t1
        行\thang\t1
        行\theng\t1
        行\txing\t1
        银行\tyin hang\t1
        长\tchang\t1
        长\tzhang\t1
        乐\tle\t1
        长乐\tchang le\t1
        """)
        func expect(_ input: String, _ text: String, _ expected: String?, preferences: InputPreferences = .init()) {
            let actual = resolver.resolve(input: input, text: text, preferences: preferences)
            precondition(actual == expected, "\(input) → \(text): \(actual ?? "nil") != \(expected ?? "nil")")
        }
        expect("xingmoliang", "星墨量", "xing mo liang ")
        expect("xml", "星墨量", "xing mo liang ")
        expect("xingmolia", "星墨量", "xing mo liang ")
        expect("nihoa", "你好", "ni hao ")
        expect("nihoa", "你好", nil, preferences: .init([.typoTolerance: false]))
        expect("ni'hao", "你好", "ni hao ")
        expect("nihao", "你好星墨量", nil)
        expect("h", "行", nil)
        expect("heng", "行", "heng ")
        expect("yh", "银行", "yin hang ")
        expect("xml", "星墨量", nil, preferences: .init([.abbreviation: false]))
        expect("xingmoliang", "星墨量!", nil)
        expect("", "你好", nil)
        expect("zhangle", "长乐", "zhang le ")
        precondition(resolver.isClearExpansion(input: "nihao", text: "你好星墨量"))
        precondition(resolver.isClearExpansion(input: "nihao", text: "你好，星墨量"))
        precondition(!resolver.isClearExpansion(input: "nihao", text: "你好𫠠"), "Unknown reading must not gate display")
        precondition(!resolver.isClearExpansion(input: "h", text: "行"), "Ambiguity must not gate display")
        let nativeUnknown = AIPronunciation(text: "你好𫠠", nativeReadings: "C\t你\tni\nC\t好\thao\nC\t𫠠\t")
        precondition(!nativeUnknown.isClearExpansion(input: "nihao", text: "你好𫠠"))
        let nativePhrase = AIPronunciation(text: "银行", nativeReadings: "P\tyin hang\nC\t银\tyin\nC\t行\t")
        precondition(nativePhrase.resolve(input: "yh", text: "银行") == "yin hang ")
        print("PASS AI pronunciation: novel word, full/abbreviated/incomplete/typo, prefix, ambiguity and no expansion")
    }
}
