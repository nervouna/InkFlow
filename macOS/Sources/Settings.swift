import AppKit
import SwiftUI

extension Notification.Name {
    static let settingsDidChange = Notification.Name("IFSettingsDidChange")
}

@MainActor
final class IFSettings: ObservableObject {
    static let sharedSettings = IFSettings(defaults: .standard)
    static let candidateCounts = Array(3...9)
    static let fontSizes = [14, 16, 18, 24, 36]
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    private func integer(for key: String, allowed: [Int], fallback: Int) -> Int {
        guard let value = defaults.object(forKey: key) as? NSNumber,
              allowed.contains(where: { value == NSNumber(value: $0) }) else { return fallback }
        return value.intValue
    }

    private func set(_ value: Int, for key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
    }

    var candidateCount: Int {
        get { integer(for: "candidateCount", allowed: Self.candidateCounts, fallback: 5) }
        set { set(Self.candidateCounts.contains(newValue) ? newValue : 5, for: "candidateCount") }
    }
    var fontSize: Int {
        get { integer(for: "fontSize", allowed: Self.fontSizes, fallback: 14) }
        set { set(Self.fontSizes.contains(newValue) ? newValue : 14, for: "fontSize") }
    }
    var vertical: Bool {
        get { integer(for: "vertical", allowed: [0, 1], fallback: 0) != 0 }
        set { set(newValue ? 1 : 0, for: "vertical") }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "外观"
    case about = "关于"
    var id: Self { self }
    var symbol: String { self == .appearance ? "paintbrush" : "info.circle" }
}

struct SettingsView: View {
    @ObservedObject var settings: IFSettings
    @State private var section: SettingsSection? = .appearance

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .accessibilityLabel("墨流拼音设置")
            .accessibilityIdentifier("settings.sidebar")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 210)
        } detail: {
            Group {
                if section == .about { about }
                else { appearance }
            }
            .navigationTitle((section ?? .appearance).rawValue)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var appearance: some View {
        Form {
            Picker("候选词方向", selection: $settings.vertical) {
                Text("水平").tag(false)
                Text("竖直").tag(true)
            }
            .accessibilityIdentifier("settings.direction")
            Picker("候选词数量", selection: $settings.candidateCount) {
                ForEach(IFSettings.candidateCounts, id: \.self) { Text(String($0)).tag($0) }
            }
            .accessibilityIdentifier("settings.count")
            Picker("候选词字号", selection: $settings.fontSize) {
                ForEach(IFSettings.fontSizes, id: \.self) { Text(String($0)).tag($0) }
            }
            .accessibilityIdentifier("settings.fontSize")
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.appearance")
    }

    private var about: some View {
        let bundle = Bundle.main
        return VStack(spacing: 12) {
            if let icon = bundle.image(forResource: (bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String) ?? "AppIcon") {
                Image(nsImage: icon).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
            }
            Text((bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "墨流拼音")
                .font(.title).bold()
            Text("版本 \((bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0") (\((bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"))")
                .foregroundStyle(.secondary)
            Text("librime \(IFEngine.version)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("settings.about")
    }
}

@MainActor
final class IFSettingsWindowController: NSWindowController {
    static let sharedController = IFSettingsWindowController(settings: .sharedSettings)
    private let settings: IFSettings

    init(settings: IFSettings) {
        self.settings = settings
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError("Settings windows are created programmatically") }

    override func loadWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "墨流拼音设置"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 700, height: 380)
        window.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(settings: settings))
        self.window = window
        window.center()
    }

    func present() {
        if window == nil { loadWindow() }
        NSApp.setActivationPolicy(.accessory)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
