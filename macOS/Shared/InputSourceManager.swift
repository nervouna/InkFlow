import Carbon
import Foundation

struct IFInputSource: Equatable, Sendable {
    let id: String
    let bundleID: String
    let name: String
    let enabled: Bool
    let selectable: Bool
    let keyboardMode: Bool
    let ascii: Bool
}

struct IFInputRoster: Sendable {
    let installed: [IFInputSource]
    let enabled: [IFInputSource]
    let selectedID: String

    func source(_ id: String) -> IFInputSource? { installed.first { $0.id == id } }
    func isEnabled(_ id: String) -> Bool { enabled.contains { $0.id == id && $0.enabled } }

}

enum IFInputIdentity {
    static let bundleID = "io.damao.inputmethod.inkflow"
    static let modeID = bundleID + ".Hans"
    static let connection = bundleID + "_Connection"
}

enum IFInputError: Error, Equatable {
    case api(String, Int32)
    case unavailable(String)
}

@MainActor protocol IFInputSourceOperations {
    func snapshot() throws -> IFInputRoster
    func register(at url: URL) throws
    func enable(_ id: String) throws
    func select(_ id: String) throws
}

/// All TIS references stay on the login session's main actor. Snapshots contain only values.
@MainActor final class IFSystemInputSources: IFInputSourceOperations {
    static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
    private func list(_ filter: [String: Any], all: Bool) throws -> [TISInputSource] {
        guard let result = TISCreateInputSourceList(filter as CFDictionary, all)?.takeRetainedValue(),
              let sources = result as? [TISInputSource] else { throw IFInputError.unavailable("TISCreateInputSourceList") }
        return sources
    }
    private func value(_ source: TISInputSource) -> IFInputSource {
        func string(_ key: CFString) -> String { Self.property(source, key) as? String ?? "" }
        func flag(_ key: CFString) -> Bool { Self.property(source, key) as? Bool == true }
        return .init(id: string(kTISPropertyInputSourceID), bundleID: string(kTISPropertyBundleID),
                     name: string(kTISPropertyLocalizedName), enabled: flag(kTISPropertyInputSourceIsEnabled),
                     selectable: flag(kTISPropertyInputSourceIsSelectCapable),
                     keyboardMode: string(kTISPropertyInputSourceType) == kTISTypeKeyboardInputMode as String,
                     ascii: flag(kTISPropertyInputSourceIsASCIICapable))
    }
    func snapshot() throws -> IFInputRoster {
        let installed = try list([kTISPropertyBundleID as String: IFInputIdentity.bundleID], all: true).map(value)
        let enabled = try list([:], all: false).map(value)
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            throw IFInputError.unavailable("TISCopyCurrentKeyboardInputSource")
        }
        let selected = value(current).id
        guard !selected.isEmpty else { throw IFInputError.unavailable("current keyboard identity") }
        return .init(installed: installed, enabled: enabled, selectedID: selected)
    }
    func register(at url: URL) throws {
        let ls = LSRegisterURL(url as CFURL, true)
        guard ls == noErr else { throw IFInputError.api("LSRegisterURL", ls) }
        let tis = TISRegisterInputSource(url as CFURL)
        guard tis == noErr else { throw IFInputError.api("TISRegisterInputSource", tis) }
    }
    private func source(_ id: String) throws -> TISInputSource {
        let matches = try list([kTISPropertyInputSourceID as String: id], all: true)
        guard let source = matches.first else { throw IFInputError.unavailable(id) }
        return source
    }
    func enable(_ id: String) throws {
        let result = TISEnableInputSource(try source(id))
        guard result == noErr else { throw IFInputError.api("TISEnableInputSource", result) }
    }
    func select(_ id: String) throws {
        let result = TISSelectInputSource(try source(id))
        guard result == noErr else { throw IFInputError.api("TISSelectInputSource", result) }
    }
}
