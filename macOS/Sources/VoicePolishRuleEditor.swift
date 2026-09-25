import SwiftUI

struct VoicePolishRuleEditor: View {
    @ObservedObject var settings: IFSettings
    let rule: VoicePolishRule
    let onSaved: (VoicePolishRule) -> Void
    let onDeleted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isEnabled: Bool
    @State private var prompt: String
    @State private var error: String?
    private let isNew: Bool
    private let icon: NSImage

    init(settings: IFSettings, rule: VoicePolishRule,
         onSaved: @escaping (VoicePolishRule) -> Void,
         onDeleted: @escaping (String) -> Void) {
        self.settings = settings
        self.rule = rule
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        isNew = !settings.voicePolishRules.contains { $0.bundleIdentifier == rule.bundleIdentifier }
        icon = VoicePolishApplicationPicker.icon(bundleIdentifier: rule.bundleIdentifier)
        _isEnabled = State(initialValue: rule.isEnabled)
        _prompt = State(initialValue: rule.prompt)
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(rule.displayName).font(.headline)
                    Text(rule.bundleIdentifier).foregroundStyle(.secondary)
                }
            }
            Form {
                Toggle("启用此应用的专属规则", isOn: $isEnabled)
                    .accessibilityIdentifier("voice.polishRules.editor.enabled")
                TextField("润色提示词", text: $prompt,
                          prompt: Text("例如：长内容按主题分段并添加简短标题"), axis: .vertical)
                    .lineLimit(5...)
                    .accessibilityIdentifier("voice.polishRules.editor.prompt")
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice.polishRules.editor.error")
            }
            HStack {
                if !isNew {
                    Button("删除", role: .destructive, action: delete)
                        .accessibilityIdentifier("voice.polishRules.editor.delete")
                }
                Spacer()
                Button("取消", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("voice.polishRules.editor.cancel")
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("voice.polishRules.editor.save")
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
    }

    private func save() {
        do {
            let saved = try settings.saveVoicePolishRule(
                originalBundleIdentifier: isNew ? nil : rule.bundleIdentifier,
                bundleIdentifier: rule.bundleIdentifier, displayName: rule.displayName,
                isEnabled: isEnabled, prompt: prompt)
            error = nil
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try settings.deleteVoicePolishRule(bundleIdentifier: rule.bundleIdentifier)
            error = nil
            onDeleted(rule.bundleIdentifier)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
