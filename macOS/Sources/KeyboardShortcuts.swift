import AppKit
import Combine

enum ShortcutAction: String, CaseIterable, Identifiable {
    case inputMode, punctuation, script, voiceHold, voiceToggle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inputMode: "切换中英文"
        case .punctuation: "切换中英文标点"
        case .script: "切换简繁体"
        case .voiceHold: "按住说话"
        case .voiceToggle: "开始或结束连续听写"
        }
    }
}

struct ShortcutBinding: Codable, Hashable {
    let keyCode: UInt16?
    private let modifierBits: UInt
    private let keyLabel: String
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }
    static let relevantFlags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    static let none = ShortcutBinding(keyCode: nil, flags: [], label: "")
    static let leftShift = ShortcutBinding(keyCode: 56, flags: .shift, label: "左 Shift")
    static let rightShift = ShortcutBinding(keyCode: 60, flags: .shift, label: "右 Shift")
    static let allCases: [ShortcutBinding] = [leftShift, rightShift,
        .init(keyCode: 59, flags: .control, label: "左 Control"),
        .init(keyCode: 62, flags: .control, label: "右 Control"),
        .init(keyCode: 58, flags: .option, label: "左 Option"),
        .init(keyCode: 61, flags: .option, label: "右 Option")]
    private static let functionKeys: [UInt16: String] = [122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
    private static let specialKeys: [UInt16: String] = [36:"Return",48:"Tab",49:"Space",51:"Delete",53:"Escape",117:"Forward Delete",123:"←",124:"→",125:"↓",126:"↑",115:"Home",119:"End",116:"Page Up",121:"Page Down",76:"Enter"]
    private init(keyCode: UInt16?, flags: NSEvent.ModifierFlags, label: String) {
        self.keyCode = keyCode; modifierBits = flags.rawValue; keyLabel = label
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.keyCode == rhs.keyCode && lhs.modifierBits == rhs.modifierBits }
    func hash(into hasher: inout Hasher) { hasher.combine(keyCode); hasher.combine(modifierBits) }
    var isModifier: Bool { Self.allCases.contains(self) }
    var title: String {
        guard keyCode != nil else { return "未设置" }
        if let modifier = Self.allCases.first(where: { $0 == self }) { return modifier.keyLabel }
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + keyLabel.uppercased()
    }
    static func recorded(from event: NSEvent) -> ShortcutBinding? {
        if event.type == .flagsChanged {
            guard !event.modifierFlags.contains(.function) else { return nil }
            return allCases.first { $0.keyCode == event.keyCode && $0.modifierIsDown(event)
                && event.modifierFlags.intersection(relevantFlags) == $0.flags }
        }
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        let label = functionKeys[event.keyCode] ?? specialKeys[event.keyCode] ?? event.charactersIgnoringModifiers ?? ""
        return .init(keyCode: event.keyCode, flags: event.modifierFlags.intersection(relevantFlags), label: label)
    }
    var validationError: String? {
        guard let keyCode else { return modifierBits == 0 && keyLabel.isEmpty ? nil : "无效的快捷键。" }
        guard keyCode <= 126, flags.isSubset(of: Self.relevantFlags), !keyLabel.isEmpty,
              keyLabel.count <= 16, keyLabel.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return "无法识别此按键，请使用其他组合键。"
        }
        if isModifier { return nil }
        if Self.allCases.contains(where: { $0.keyCode == keyCode }) || [54,55,57,63].contains(keyCode) {
            return "请选择单独的 Shift、Control、Option，或带普通按键的组合键。"
        }
        if keyCode == 48 && flags.isEmpty { return "Tab 保留用于采纳 AI 建议与焦点导航。" }
        guard !flags.intersection([.command,.control,.option]).isEmpty || Self.functionKeys[keyCode] != nil else {
            return "请加入 Command、Control 或 Option，避免占用日常输入按键。"
        }
        if (keyCode == 49 && (flags.contains(.command) || flags == .control || flags == [.control,.option]))
            || (keyCode == 48 && (flags.contains(.command) || flags.subtracting(.shift) == .control))
            || (keyCode == 53 && flags.contains(.command))
            || ([12,13,4,46].contains(keyCode) && flags == .command)
            || ([0,6,7,8,9].contains(keyCode) && flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option))
            || ([18,19,20,21,22,23,26,28,25,29].contains(keyCode) && flags == [.command,.shift]) {
            return "此组合通常用于系统或应用常用操作，请选择其他组合键。"
        }
        return nil
    }
    func matches(_ event: NSEvent) -> Bool {
        !isModifier && keyCode != nil && event.type == .keyDown && event.keyCode == keyCode
            && event.modifierFlags.intersection(Self.relevantFlags) == flags
    }
    func modifierIsDown(_ event: NSEvent) -> Bool {
        let mask: UInt, family: UInt
        switch keyCode {
        case 56: (mask,family) = (0x2,0x6)
        case 60: (mask,family) = (0x4,0x6)
        case 59: (mask,family) = (0x1,0x2001)
        case 62: (mask,family) = (0x2000,0x2001)
        case 58: (mask,family) = (0x20,0x60)
        case 61: (mask,family) = (0x40,0x60)
        default: return false
        }
        let bits = event.modifierFlags.rawValue
        return bits & family == 0 ? event.modifierFlags.contains(flags) : bits & mask != 0
    }
    var menuEquivalent: String {
        guard !isModifier, let keyCode else { return "" }
        if let number = Self.functionKeys[keyCode].flatMap({ Int($0.dropFirst()) }), let scalar = UnicodeScalar(0xF703 + number) { return String(scalar) }
        let specialCodes: [UInt16: UInt32] = [36:13,48:9,49:32,51:8,53:27,117:0xF728,123:0xF702,124:0xF703,125:0xF701,126:0xF700,115:0xF729,119:0xF72B,116:0xF72C,121:0xF72D,76:3]
        if let code = specialCodes[keyCode], let scalar = UnicodeScalar(code) { return String(scalar) }
        return keyLabel.lowercased()
    }
}

@MainActor
final class KeyboardShortcuts: ObservableObject {
    @Published private var bindings: [ShortcutAction: ShortcutBinding] = [:]
    @Published var error: String?
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    init(defaults: UserDefaults) {
        self.defaults = defaults
        for action in ShortcutAction.allCases {
            let stored = defaults.data(forKey: "shortcut.\(action.rawValue)").flatMap { try? JSONDecoder().decode(ShortcutBinding.self, from: $0) }
            let value = stored ?? Self.defaultBinding(for: action)
            bindings[action] = validationError(value, for: action) == nil ? value : Self.defaultBinding(for: action)
        }
        for (index, action) in ShortcutAction.allCases.enumerated() {
            if ShortcutAction.allCases.prefix(index).contains(where: { conflicts(action, $0, binding(for: action)) }) { bindings[action] = ShortcutBinding.none }
        }
    }
    private static func defaultBinding(for action: ShortcutAction) -> ShortcutBinding {
        switch action {
        case .inputMode: .leftShift
        case .voiceHold, .voiceToggle: .rightShift
        case .punctuation, .script: .none
        }
    }
    func binding(for action: ShortcutAction) -> ShortcutBinding { bindings[action] ?? .none }
    private func validationError(_ value: ShortcutBinding, for action: ShortcutAction) -> String? {
        if let error = value.validationError { return error }
        if value.isModifier && [.punctuation,.script].contains(action) { return "请使用组合键切换标点或简繁体。" }
        return nil
    }
    private func conflicts(_ action: ShortcutAction, _ other: ShortcutAction, _ value: ShortcutBinding) -> Bool {
        guard action != other, value != .none, binding(for: other) == value else { return false }
        return Set([action,other]) != Set([.voiceHold,.voiceToggle])
    }
    @discardableResult func set(_ value: ShortcutBinding, for action: ShortcutAction) -> Bool {
        if let reason = validationError(value, for: action) { error = reason; return false }
        if let other = ShortcutAction.allCases.first(where: { conflicts(action, $0, value) }) {
            error = "此按键已用于“\(other.title)”，请先更改或清除该绑定。"; return false
        }
        guard let data = try? JSONEncoder().encode(value) else { error = "无法保存此快捷键。"; return false }
        error = nil; bindings[action] = value; revision += 1
        defaults.set(data, forKey: "shortcut.\(action.rawValue)")
        return true
    }
    func restoreDefaults() {
        error = nil
        for action in ShortcutAction.allCases {
            let value = Self.defaultBinding(for: action)
            bindings[action] = value
            defaults.set(try? JSONEncoder().encode(value), forKey: "shortcut.\(action.rawValue)")
        }
        revision += 1
    }
    func title(for action: ShortcutAction) -> String { title(for: binding(for: action), action: action) }
    func title(for value: ShortcutBinding, action: ShortcutAction) -> String {
        guard value != .none else { return value.title }
        if action == .voiceHold { return "按住 \(value.title)" }
        if action == .voiceToggle { return "双击 \(value.title)" }
        return value.isModifier ? "轻按 \(value.title)" : value.title
    }
}
