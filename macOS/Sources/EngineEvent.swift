import AppKit
import InkFlowRime

@MainActor
extension IFEngine {
    @discardableResult
    func event(_ event: NSEvent, capturedAt: TimeInterval? = nil) -> Bool {
        guard available else { return false }
        let flags = event.modifierFlags
        guard flags.intersection([.command, .control, .option]).isEmpty else { return input(-1, isRepeat: event.isARepeat, capturedAt: capturedAt) }
        let key: Int32
        switch event.keyCode {
        case 36, 76: key = 0xff0d
        case 48: key = 0xff09
        case 51: key = 0xff08
        case 53: key = 0xff1b
        case 117: key = 0xffff
        case 123: key = 0xff51
        case 124: key = 0xff53
        case 125: key = 0xff54
        case 126: key = 0xff52
        case 115: key = 0xff50
        case 119: key = 0xff57
        case 116: key = 0xff55
        case 121: key = 0xff56
        default:
            guard let characters = event.characters, characters.utf16.count == 1,
                  let character = characters.utf16.first, character <= 127 else {
                return input(-2, isRepeat: event.isARepeat, capturedAt: capturedAt)
            }
            key = Int32(character)
        }
        return input(key, modifiers: flags.contains(.shift) ? 1 : 0, isRepeat: event.isARepeat, capturedAt: capturedAt)
    }

}
