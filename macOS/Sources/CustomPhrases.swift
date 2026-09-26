import SwiftUI
import InkFlowDomain

struct CustomPhrasesView: View {
    @ObservedObject var settings: IFSettings
    @State private var selection: UUID?
    @State private var editor: CustomPhrase?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义短语").font(.headline)
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
