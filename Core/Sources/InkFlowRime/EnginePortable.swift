import InkFlowDomain
import InkFlowPortable
import Foundation

let ifrOK = IFRStatus(IFR_OK)

func ifrString(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map(String.init(cString:)) ?? ""
}

func withCStrings<Result>(_ strings: [String], _ body: ([UnsafePointer<CChar>?]) -> Result) -> Result {
    let copies = strings.map { strdup($0) }
    defer { copies.forEach { free($0) } }
    return body(copies.map { UnsafePointer($0) })
}

enum CompiledFiles {
    static let names: [String] = (0..<ifr_compiled_file_count()).map { ifrString(ifr_compiled_file_name($0)) }
}

extension InputPreferences {
    var optionMask: UInt32 {
        InputOption.allCases.enumerated().reduce(0) { $0 | ((self[$1.element] ? 1 : 0) << UInt32($1.offset)) }
    }

    init(optionMask mask: UInt32) {
        self.init(Dictionary(uniqueKeysWithValues: InputOption.allCases.enumerated().map {
            ($1, mask & (1 << UInt32($0)) != 0)
        }))
    }
}

final class PortableSnapshot {
    let handle: OpaquePointer

    init?(_ session: OpaquePointer?) {
        var created: OpaquePointer?
        guard let session, ifr_session_snapshot(session, &created) == ifrOK, let created else { return nil }
        handle = created
    }

    deinit { ifr_snapshot_free(handle) }

    var input: String { ifrString(ifr_snapshot_input(handle)) }
    var preedit: String { ifrString(ifr_snapshot_preedit(handle)) }
    var caretBytes: Int { Int(ifr_snapshot_caret(handle)) }
    var rawCaretBytes: Int { Int(ifr_snapshot_raw_caret(handle)) }
    var selectionStart: Int { Int(ifr_snapshot_selection_start(handle)) }
    var candidateCount: Int { Int(ifr_snapshot_candidate_count(handle)) }
    var page: Int { Int(ifr_snapshot_page(handle)) }
    var highlighted: Int { Int(ifr_snapshot_highlighted(handle)) }
    func text(_ index: Int) -> String { ifrString(ifr_snapshot_candidate_text(handle, index)) }
    func comment(_ index: Int) -> String { ifrString(ifr_snapshot_candidate_comment(handle, index)) }

    func evidence(_ index: Int) -> (row: String, type: String, corrected: Bool)? {
        guard let pointer = ifr_snapshot_candidate_evidence(handle, index) else { return nil }
        let row = String(cString: pointer)
        let fields = row.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 8 else { return nil }
        return (row, String(fields[6]), fields[7] == "1")
    }

    var content: EngineSnapshot {
        let preedit = preedit
        return EngineSnapshot(preedit: preedit,
            cursor: IFEngine.utf16Cursor(in: preedit, byteOffset: caretBytes),
            candidates: (0..<candidateCount).map(text), page: page, highlight: highlighted,
            hasSelectedPrefix: selectionStart > 0)
    }
}

func portableReply(_ reply: OpaquePointer) -> IFRimeChannel.Reply {
    defer { ifr_reply_free(reply) }
    return IFRimeChannel.Reply(status: ifrString(ifr_reply_status(reply)), body: ifrString(ifr_reply_body(reply)))
}

func configurationMessage(_ code: String) -> String {
    switch code {
    case "invalid-code": "输入码只能包含英文字母 a–z。"
    case "control-character": "短语不能包含换行、制表符或其他控制字符。"
    case "empty-text": "请输入短语内容。"
    case "invalid-data": "自定义短语数据格式无效。"
    case "duplicate": "该输入码和短语已存在。"
    case "phrase-write": "无法保存自定义短语，请检查墨流数据目录的可用空间和写入权限。"
    case "session-reload": "无法重新载入输入方案，请重试或重启墨流。"
    case "missing-prism": "缺少已编译的拼音规则，设置尚未应用。请重启墨流后重试。"
    case "schema-open": "无法打开输入方案，设置尚未应用。"
    case "patch-init": "无法创建输入设置。"
    case "patch-load": "无法载入输入设置。"
    case "schema-restore": "恢复临时输入方案配置失败，请重启墨流后重试。"
    default: "无法应用输入设置，请重启墨流后重试。"
    }
}

package enum IFPortableResources {
    package static func compile(_ shared: String, _ user: String, _ cache: String) -> Bool {
        ifr_resources_compile(shared, user, cache) == ifrOK
    }

    package static func probe(_ shared: String, _ user: String, _ cache: String) -> String? {
        ifr_resources_probe(shared, user, cache) == ifrOK ? nil : ifrString(ifr_last_error())
    }
}

package enum IFPortablePersonalData {
    package static let names = ["pinyin_simp", "inkflow_shared_english", "inkflow_voice_alias"]

    package static func export(user: String) throws -> [String: String?] {
        var exported: OpaquePointer?
        guard ifr_personal_export(user, &exported) == ifrOK, let exported else {
            throw IFDictionaryUpdateError(.apply, "personal-export", detail: ifrString(ifr_last_error()))
        }
        defer { ifr_personal_export_free(exported) }
        return Dictionary(uniqueKeysWithValues: names.map { name in
            (name, ifr_personal_export_text(exported, name).map { String(cString: $0) })
        })
    }

    package static func restore(user: String, name: String, snapshot: String) -> Bool {
        IFPersonalDataSnapshot(user, name, snapshot, 1) == 0
    }
}
