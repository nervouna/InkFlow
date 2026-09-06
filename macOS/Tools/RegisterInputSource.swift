import Carbon
import Foundation

private let bundleID = "io.damao.inputmethod.inkflow"

private func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
}

private func sources(_ identifier: String) -> [TISInputSource] {
    let filter = [kTISPropertyBundleID as String: bundleID, kTISPropertyInputSourceID as String: identifier] as CFDictionary
    return TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
}

private func enabled(_ identifier: String) -> Bool {
    let matches = sources(identifier)
    return matches.count == 1 && property(matches[0], kTISPropertyInputSourceIsEnabled) as? Bool == true
}

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

let arguments = CommandLine.arguments
let verify = arguments.count == 3 && arguments[2] == "--verify-enabled"
guard arguments.count == 2 || verify else {
    fail("Usage: register-input-source /path/to/InkFlow.app [--verify-enabled]", code: 2)
}
let url = URL(fileURLWithPath: arguments[1], isDirectory: true)
guard Bundle(url: url)?.bundleIdentifier == bundleID else {
    fail("Unexpected input method bundle identifier.", code: 2)
}
if !verify {
    let launchStatus = LSRegisterURL(url as CFURL, true)
    print("launch_services_status=\(launchStatus)")
    guard launchStatus == noErr else { exit(1) }
    let status = TISRegisterInputSource(url as CFURL)
    print("registration_status=\(status)")
    guard status == noErr else { exit(1) }
}
let matches = sources("\(bundleID).Hans")
print("registered_mode_count=\(matches.count)")
var valid = matches.count == 1
if valid {
    let source = matches[0]
    let name = property(source, kTISPropertyLocalizedName) as? String ?? ""
    let selectable = property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool == true
    let keyboardMode = property(source, kTISPropertyInputSourceType) as? String == kTISTypeKeyboardInputMode as String
    print("mode_name=\(name)\nmode_select_capable=\(selectable ? 1 : 0)")
    valid = ["墨流拼音", "InkFlow Pinyin"].contains(name) && selectable && keyboardMode
}
if valid && verify {
    let parentEnabled = enabled(bundleID), modeEnabled = enabled("\(bundleID).Hans")
    print("parent_enabled=\(parentEnabled ? 1 : 0)\nmode_enabled=\(modeEnabled ? 1 : 0)")
    valid = parentEnabled && modeEnabled
}
guard valid else {
    fail("Expected named, selectable Chinese mode is unavailable\(verify ? " or not enabled" : "").", code: 1)
}
if !verify {
    print("Registered only. Add InkFlow in System Settings, then run --verify-enabled. Registration does not enable or select it.")
}
