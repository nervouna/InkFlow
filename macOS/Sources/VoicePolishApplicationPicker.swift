import AppKit
import UniformTypeIdentifiers

@MainActor
enum VoicePolishApplicationPicker {
    struct Descriptor: Equatable, Sendable {
        let bundleIdentifier: String
        let displayName: String
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    typealias Action = @MainActor () throws -> Descriptor?

    static func pick() throws -> Descriptor? {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.prompt = "选择"
        panel.message = "选择一个应用，为它配置语音润色规则。"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try descriptor(at: url)
    }

    static func descriptor(at url: URL) throws -> Descriptor {
        guard url.pathExtension.lowercased() == "app",
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else {
            throw Failure("请选择有效的 macOS 应用。")
        }
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let validated = try VoicePolishRule.validated(bundleIdentifier: bundleIdentifier,
            displayName: displayName, isEnabled: true, prompt: "应用语音润色规则")
        return Descriptor(bundleIdentifier: validated.bundleIdentifier, displayName: validated.displayName)
    }

    static func icon(bundleIdentifier: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
