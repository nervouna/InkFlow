import AppKit
import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject var shortcuts: KeyboardShortcuts

    var body: some View {
        Form {
            Section("输入切换") {
                shortcut(.inputMode)
                shortcut(.punctuation)
                shortcut(.script)
            }
            Section("语音") {
                shortcut(.voiceHold)
                shortcut(.voiceToggle)
            }
            Section {
                Text("点击快捷键后按下新的组合。Esc 取消，Delete 清除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = shortcuts.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("shortcuts.error")
                }
                Button("恢复默认快捷键", action: shortcuts.restoreDefaults)
                    .accessibilityIdentifier("shortcuts.restoreDefaults")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.shortcuts")
    }

    private func shortcut(_ action: ShortcutAction) -> some View {
        LabeledContent(action.title) {
            ShortcutRecorder(
                label: action.title,
                value: shortcuts.title(for: action),
                identifier: "shortcuts.\(action.rawValue)",
                save: { shortcuts.set($0, for: action) }
            )
            .frame(width: 200, height: 26)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let label: String
    let value: String
    let identifier: String
    let save: (ShortcutBinding) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorderContainer {
        let container = ShortcutRecorderContainer()
        updateNSView(container, context: context)
        return container
    }

    func updateNSView(_ container: ShortcutRecorderContainer, context: Context) {
        let button = container.button
        button.bindingTitle = value
        button.save = save
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        if !button.recording { button.title = value }
    }
}

/// Keep the native button below the SwiftUI representable's accessibility proxy.
private final class ShortcutRecorderContainer: NSView {
    let button = ShortcutRecorderButton()

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
        button.autoresizingMask = [.width, .height]
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("Shortcut recorder is programmatic") }

    override func layout() {
        super.layout()
        button.frame = bounds
    }
}

/// Captures only while this button is the first responder. No global event monitor.
private final class ShortcutRecorderButton: NSButton {
    var bindingTitle = "未设置"
    var save: (ShortcutBinding) -> Bool = { _ in false }
    private(set) var recording = false
    private var pendingModifier: ShortcutBinding?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) { fatalError("Shortcut recorder is programmatic") }
    override var acceptsFirstResponder: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        beginRecording()
        return recording
    }

    @objc private func beginRecording() {
        guard window?.makeFirstResponder(self) == true, window?.firstResponder === self else { return }
        pendingModifier = nil
        recording = true
        title = "请按快捷键…"
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    private func finishRecording() {
        recording = false
        pendingModifier = nil
        title = bindingTitle
    }

    private func record(_ binding: ShortcutBinding) {
        if save(binding) { finishRecording() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }
        pendingModifier = nil
        let flags = event.modifierFlags.intersection(ShortcutBinding.relevantFlags)
        if flags.isEmpty, event.keyCode == 53 { finishRecording(); return }
        if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            record(.none)
            return
        }
        if let binding = ShortcutBinding.recorded(from: event) { record(binding) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { super.flagsChanged(with: event); return }
        if event.modifierFlags.intersection(ShortcutBinding.relevantFlags).isEmpty {
            if let pendingModifier { record(pendingModifier) }
            pendingModifier = nil
        } else {
            pendingModifier = ShortcutBinding.recorded(from: event)
        }
    }
}
