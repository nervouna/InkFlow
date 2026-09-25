import SwiftUI

struct VoicePolishRuleRow: View {
    let rule: VoicePolishRule
    let onToggle: (VoicePolishRule) -> Void
    let onEdit: (VoicePolishRule) -> Void
    let onDelete: (VoicePolishRule) -> Void

    var body: some View {
        HStack {
            Image(nsImage: VoicePolishApplicationPicker.icon(bundleIdentifier: rule.bundleIdentifier))
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(rule.displayName)
                Text(rule.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(rule.isEnabled ? "停用 \(rule.displayName)" : "启用 \(rule.displayName)",
                   systemImage: rule.isEnabled ? "checkmark.circle.fill" : "circle",
                   action: toggle)
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("voice.polishRules.enable.\(rule.bundleIdentifier)")
            Button("编辑 \(rule.displayName)", systemImage: "pencil", action: edit)
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("voice.polishRules.edit.\(rule.bundleIdentifier)")
            Button("删除 \(rule.displayName)", systemImage: "trash", role: .destructive, action: delete)
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("voice.polishRules.delete.\(rule.bundleIdentifier)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.polishRules.row.\(rule.bundleIdentifier)")
    }

    private func toggle() { onToggle(rule) }
    private func edit() { onEdit(rule) }
    private func delete() { onDelete(rule) }
}
