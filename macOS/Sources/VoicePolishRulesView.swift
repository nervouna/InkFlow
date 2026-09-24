import SwiftUI

struct VoicePolishRulesView: View {
    @ObservedObject var settings: IFSettings
    let pickApplication: VoicePolishApplicationPicker.Action

    @Environment(\.dismiss) private var dismiss
    @State private var editor: VoicePolishRule?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                if let message = settings.voicePolishRulesLoadError ?? error {
                    Text(message)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("voice.polishRules.error")
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(settings.voicePolishRules) { rule in
                            VoicePolishRuleRow(rule: rule, onToggle: toggle, onEdit: edit, onDelete: delete)
                            Divider()
                        }
                    }
                }
                .accessibilityIdentifier("voice.polishRules.list")
                .overlay {
                    if settings.voicePolishRules.isEmpty && settings.voicePolishRulesLoadError == nil {
                        ContentUnavailableView("尚无应用规则", systemImage: "text.badge.plus",
                                               description: Text("添加应用后，可为它设置专属语音润色风格。"))
                            .accessibilityIdentifier("voice.polishRules.empty")
                    }
                }
                HStack {
                    Text("\(settings.voicePolishRules.count) 条")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("voice.polishRules.count")
                    Spacer()
                    Button("添加应用", systemImage: "plus", action: add)
                        .disabled(settings.voicePolishRulesLoadError != nil
                                  || settings.voicePolishRules.count >= VoicePolishRule.maximumRuleCount)
                        .accessibilityIdentifier("voice.polishRules.add")
                    Button("完成", action: dismiss.callAsFunction)
                        .accessibilityIdentifier("voice.polishRules.done")
                }
            }
            .padding()
            .navigationTitle("应用语音润色")
        }
        .frame(minWidth: 560, minHeight: 420)
        .sheet(item: $editor) { rule in
            VoicePolishRuleEditor(settings: settings, rule: rule,
                                  onSaved: didSave, onDeleted: didDelete)
        }
    }

    private func add() {
        do {
            guard let application = try pickApplication() else { return }
            if let existing = settings.voicePolishRules.first(where: {
                $0.bundleIdentifier == application.bundleIdentifier
            }) {
                editor = existing
            } else {
                editor = VoicePolishRule(bundleIdentifier: application.bundleIdentifier,
                                         displayName: application.displayName,
                                         isEnabled: true, prompt: "")
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func edit(_ rule: VoicePolishRule) {
        editor = rule
        error = nil
    }

    private func toggle(_ rule: VoicePolishRule) {
        do {
            try settings.setVoicePolishRuleEnabled(bundleIdentifier: rule.bundleIdentifier,
                                                   enabled: !rule.isEnabled)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ rule: VoicePolishRule) {
        do {
            try settings.deleteVoicePolishRule(bundleIdentifier: rule.bundleIdentifier)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func didSave(_ rule: VoicePolishRule) {
        editor = nil
        error = nil
    }

    private func didDelete(_ bundleIdentifier: String) {
        editor = nil
        error = nil
    }
}
