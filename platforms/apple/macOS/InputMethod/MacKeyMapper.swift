import AppKit
import InkFlowAppleEngine

enum MacKeyMapper {
    static func map(_ event: NSEvent) -> EngineKeyEvent? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.intersection([.command, .control, .option]).isEmpty {
            return nil
        }

        var modifiers: UInt32 = 0
        if flags.contains(.shift) { modifiers |= EngineModifier.shift }
        if flags.contains(.capsLock) { modifiers |= EngineModifier.capsLock }

        let namedKey: UInt32?
        switch event.keyCode {
        case 51: namedKey = EngineKey.backspace
        case 117: namedKey = EngineKey.deleteForward
        case 36, 76: namedKey = EngineKey.return
        case 53: namedKey = EngineKey.escape
        case 48: namedKey = EngineKey.tab
        case 123: namedKey = EngineKey.left
        case 124: namedKey = EngineKey.right
        case 125: namedKey = EngineKey.down
        case 126: namedKey = EngineKey.up
        case 116: namedKey = EngineKey.pageUp
        case 121: namedKey = EngineKey.pageDown
        case 115: namedKey = EngineKey.home
        case 119: namedKey = EngineKey.end
        default: namedKey = nil
        }
        if let namedKey {
            return EngineKeyEvent(key: namedKey, modifiers: modifiers)
        }

        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
              event.charactersIgnoringModifiers?.unicodeScalars.count == 1 else {
            return nil
        }
        return EngineKeyEvent(key: scalar.value, modifiers: modifiers)
    }
}
