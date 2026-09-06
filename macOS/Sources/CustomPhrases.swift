import SwiftUI

struct CustomPhrase: Codable, Equatable, Identifiable {
    let id: UUID
    let code: String
    let text: String

    static func validated(id: UUID = UUID(), code: String, text: String) throws -> Self {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty, code.utf8.allSatisfy({ (97...122).contains($0) }) else {
            throw CustomPhraseError("输入码只能包含英文字母 a–z。")
        }
        guard text.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw CustomPhraseError("短语不能包含换行、制表符或其他控制字符。")
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CustomPhraseError("请输入短语内容。") }
        return Self(id: id, code: code, text: text)
    }

    static func validate(_ phrases: [Self]) throws {
        var ids = Set<UUID>()
        var pairs = Set<String>()
        for phrase in phrases {
            guard try validated(id: phrase.id, code: phrase.code, text: phrase.text) == phrase,
                  ids.insert(phrase.id).inserted else {
                throw CustomPhraseError("自定义短语数据格式无效。")
            }
            guard pairs.insert(phrase.code + "\t" + phrase.text).inserted else {
                throw CustomPhraseError("该输入码和短语已存在。")
            }
        }
    }
}

struct CustomPhraseError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct CustomPhrasesView: View {
    @ObservedObject var settings: IFSettings
    @State private var selection: UUID?
    @State private var editor: CustomPhrase?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义短语").font(.headline)
            Text("输入完整输入码时，短语优先显示。同一输入码可添加多个短语。")
                .font(.callout).foregroundStyle(.secondary)
            if let message = settings.customPhrasesLoadError ?? settings.inputSettingsError ?? error {
                Text(message).font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("phrases.error")
            }
            Table(settings.customPhrases, selection: $selection) {
                TableColumn("输入码", value: \.code).width(min: 80, ideal: 100, max: 150)
                TableColumn("短语", value: \.text)
            }
            .accessibilityIdentifier("phrases.list")
            .overlay {
                if settings.customPhrases.isEmpty && settings.customPhrasesLoadError == nil {
                    Text("尚无自定义短语，点击「添加」创建。").foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("phrases.empty")
                }
            }
            HStack {
                Button("添加", systemImage: "plus") {
                    editor = CustomPhrase(id: UUID(), code: "", text: "")
                }
                .disabled(settings.customPhrasesLoadError != nil)
                .accessibilityIdentifier("phrases.add")
                Button("编辑") { editor = selectedPhrase }
                    .disabled(selectedPhrase == nil)
                    .accessibilityIdentifier("phrases.edit")
                Button("删除", role: .destructive) {
                    guard let selection else { return }
                    do {
                        try settings.deleteCustomPhrase(id: selection)
                        self.selection = nil
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
                .disabled(selectedPhrase == nil)
                .accessibilityIdentifier("phrases.delete")
                Spacer()
                Text("\(settings.customPhrases.count) 条").foregroundStyle(.secondary)
            }
            Text("自动保存；正在输入的组合结束后生效。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .sheet(item: $editor) { phrase in
            CustomPhraseEditor(settings: settings, phrase: phrase) { selection = $0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.personalization")
    }

    private var selectedPhrase: CustomPhrase? { settings.customPhrases.first { $0.id == selection } }
}

struct CustomPhraseEditor: View {
    @ObservedObject var settings: IFSettings
    let phrase: CustomPhrase
    let onSave: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code: String
    @State private var text: String
    @State private var error: String?
    @FocusState private var codeFocused: Bool

    init(settings: IFSettings, phrase: CustomPhrase, onSave: @escaping (UUID) -> Void) {
        self.settings = settings
        self.phrase = phrase
        self.onSave = onSave
        _code = State(initialValue: phrase.code)
        _text = State(initialValue: phrase.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "添加自定义短语" : "编辑自定义短语").font(.headline)
            Form {
                TextField("输入码", text: $code, prompt: Text("例如 dz"))
                    .focused($codeFocused)
                    .accessibilityIdentifier("phrases.editor.code")
                TextField("短语", text: $text, prompt: Text("例如 台北市信义区"))
                    .accessibilityIdentifier("phrases.editor.text")
            }
            Text("输入码使用 a–z；大写字母会自动转为小写。")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
                    .accessibilityIdentifier("phrases.editor.error")
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("phrases.editor.cancel")
                Button("保存") {
                    do {
                        let saved = try settings.saveCustomPhrase(id: isNew ? nil : phrase.id, code: code, text: text)
                        onSave(saved.id)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("phrases.editor.save")
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { codeFocused = true }
    }

    private var isNew: Bool { phrase.code.isEmpty }
}
