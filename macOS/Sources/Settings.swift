import AppKit
import SwiftUI

extension Notification.Name {
    static let settingsDidChange = Notification.Name("IFSettingsDidChange")
}

@MainActor
final class IFSettings: ObservableObject {
    enum PagingKeys: String, CaseIterable {
        case brackets = "[]"
        case minusEqual = "-="
    }

    static let sharedSettings: IFSettings = {
        // Only a process-local argument-domain flag isolates the exact-initializer harness.
        // Persisted preferences can never select this credential store.
        let isolated = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["IFIsolatedAICredentials"] as? Bool == true
        let credentials: any AICredentialStore = isolated ? MemoryAICredentialStore() : KeychainAICredentialStore()
        let service: any VoiceRecognitionServing
        if let mode = VoiceRecognitionFixture.configured { service = VoiceRecognitionFixture(mode: mode) }
        else { service = AppleVoiceRecognizer() }
        let settings = IFSettings(defaults: .standard, aiCredentials: credentials, voiceService: service)
        if !isolated {
            Task(priority: .utility) { await settings.voice.prepareIfAuthorized() }
        }
        return settings
    }()
    static let candidateCounts = Array(3...9)
    static let fontSizes = [14, 16, 18, 24, 36]
    private let defaults: UserDefaults
    let smart: IFSmartSettings
    let voice: VoicePreparation
    private(set) var customPhrases: [CustomPhrase] = []
    private(set) var customPhrasesLoadError: String?
    @Published var inputSettingsError: String?

    init(defaults: UserDefaults, aiCredentials: any AICredentialStore = MemoryAICredentialStore(),
         voiceService: any VoiceRecognitionServing = AppleVoiceRecognizer()) {
        self.defaults = defaults
        voice = VoicePreparation(service: voiceService)
        smart = IFSmartSettings(defaults: defaults, credentials: aiCredentials)
        guard let stored = defaults.object(forKey: "customPhrases") else { return }
        do {
            guard let data = stored as? Data else { throw CustomPhraseError("数据格式无效。") }
            let phrases = try JSONDecoder().decode([CustomPhrase].self, from: data)
            try CustomPhrase.validate(phrases)
            customPhrases = phrases
        } catch {
            customPhrasesLoadError = "无法读取已保存的自定义短语，原数据已保留。请先恢复偏好设置的备份。"
        }
    }

    @discardableResult
    func saveCustomPhrase(id: UUID? = nil, code: String, text: String) throws -> CustomPhrase {
        let phrase = try CustomPhrase.validated(id: id ?? UUID(), code: code, text: text)
        var updated = customPhrases
        if let id {
            guard let index = updated.firstIndex(where: { $0.id == id }) else {
                throw CustomPhraseError("要编辑的短语已不存在。")
            }
            updated[index] = phrase
        } else { updated.append(phrase) }
        try persistCustomPhrases(updated)
        return phrase
    }

    func deleteCustomPhrase(id: UUID) throws {
        guard customPhrases.contains(where: { $0.id == id }) else {
            throw CustomPhraseError("要删除的短语已不存在。")
        }
        try persistCustomPhrases(customPhrases.filter { $0.id != id })
    }

    private func persistCustomPhrases(_ phrases: [CustomPhrase]) throws {
        if let customPhrasesLoadError { throw CustomPhraseError(customPhrasesLoadError) }
        try CustomPhrase.validate(phrases)
        let data = try JSONEncoder().encode(phrases)
        objectWillChange.send()
        defaults.set(data, forKey: "customPhrases")
        customPhrases = phrases
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
    }

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
    var thunderMode: Bool {
        get { integer(for: "thunderMode", allowed: [0, 1], fallback: 0) != 0 }
        set { set(newValue ? 1 : 0, for: "thunderMode") }
    }
    var voicePolishEnabled: Bool {
        get { integer(for: "voicePolishEnabled", allowed: [0, 1], fallback: 0) != 0 }
        set { set(newValue ? 1 : 0, for: "voicePolishEnabled") }
    }

    private func inputValue(_ option: InputOption) -> Bool {
        integer(for: "input.\(option.rawValue)", allowed: [0, 1], fallback: option.defaultValue ? 1 : 0) != 0
    }

    var fuzzyEnabled: Bool {
        get { [.fuzzyZ, .fuzzyC, .fuzzyS].contains { inputValue($0) } }
        set { setInputOptions([.fuzzyZ: newValue, .fuzzyC: newValue, .fuzzyS: newValue]) }
    }

    var pagingKeys: PagingKeys {
        get { !inputValue(.bracketPaging) && inputValue(.minusEqualPaging) ? .minusEqual : .brackets }
        set { setInputOptions([.bracketPaging: newValue == .brackets, .minusEqualPaging: newValue == .minusEqual]) }
    }

    var inputPreferences: InputPreferences {
        var values = Dictionary(uniqueKeysWithValues: InputOption.allCases.map { ($0, inputValue($0)) })
        // Canonicalize legacy independent choices before exposing a composition snapshot.
        for option: InputOption in [.fuzzyZ, .fuzzyC, .fuzzyS] { values[option] = fuzzyEnabled }
        values[.bracketPaging] = pagingKeys == .brackets
        values[.minusEqualPaging] = pagingKeys == .minusEqual
        return InputPreferences(values)
    }

    func setInputOption(_ option: InputOption, enabled: Bool) {
        switch option {
        case .fuzzyZ, .fuzzyC, .fuzzyS: fuzzyEnabled = enabled
        case .bracketPaging: pagingKeys = enabled ? .brackets : .minusEqual
        case .minusEqualPaging: pagingKeys = enabled ? .minusEqual : .brackets
        default: setInputOptions([option: enabled])
        }
    }

    private func setInputOptions(_ values: [InputOption: Bool]) {
        guard values.contains(where: { inputValue($0.key) != $0.value }) else { return }
        objectWillChange.send()
        for (option, enabled) in values { defaults.set(enabled, forKey: "input.\(option.rawValue)") }
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "外观"
    case input = "输入"
    case personalization = "个性化"
    case smart = "AI 服务"
    case voice = "语音"
    case dictionaries = "词库"
    case about = "关于"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .input: "keyboard"
        case .personalization: "person.crop.circle"
        case .smart: "sparkles"
        case .voice: "mic"
        case .dictionaries: "books.vertical"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: IFSettings
    var dictionaries: IFDictionaryCoordinator?
    @State private var section: SettingsSection?

    init(settings: IFSettings, dictionaries: IFDictionaryCoordinator? = nil, initialSection: SettingsSection = .appearance) {
        self.settings = settings
        self.dictionaries = dictionaries
        _section = State(initialValue: initialSection)
    }

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
                else if section == .input { input }
                else if section == .personalization { CustomPhrasesView(settings: settings) }
                else if section == .smart { SmartSettingsView(smart: settings.smart) }
                else if section == .voice { VoiceSettingsView(settings: settings, smart: settings.smart) }
                else if section == .dictionaries { DictionarySettingsView(coordinator: dictionaries) }
                else { appearance }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
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
            Toggle("庆祝模式", isOn: $settings.thunderMode)
                .help("每次输入和上屏时在光标处绽放彩花")
                .accessibilityIdentifier("settings.thunderMode")
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.appearance")
    }

    private func inputToggle(_ title: String, _ option: InputOption) -> some View {
        Toggle(title, isOn: Binding(get: { settings.inputPreferences[option] },
                                   set: { settings.setInputOption(option, enabled: $0) }))
            .accessibilityIdentifier("settings.input.\(option.rawValue)")
    }

    private func punctuationPicker(_ key: String, mapped: String, option: InputOption) -> some View {
        Picker("按下 \(key) 时输入", selection: Binding(get: { settings.inputPreferences[option] },
                                                   set: { settings.setInputOption(option, enabled: $0) })) {
            Text("原样输入").tag(false)
            Text("输入 \(mapped)").tag(true)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings.input.\(option.rawValue)")
    }

    private var input: some View {
        Form {
            Section {
                inputToggle("简拼", .abbreviation)
                inputToggle("自动纠错", .typoTolerance)
                Toggle("模糊音", isOn: $settings.fuzzyEnabled)
                    .accessibilityIdentifier("settings.input.fuzzy")
            }
            Section {
                inputToggle("显示 Emoji 候选", .emoji)
                LabeledContent("翻页") {
                    Picker("翻页", selection: $settings.pagingKeys) {
                        ForEach(IFSettings.PagingKeys.allCases, id: \.self) { keys in
                            Text(keys.rawValue).tag(keys)
                                .accessibilityIdentifier("settings.input.paging.\(keys == .brackets ? "brackets" : "minusEqual")")
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                }
            }
            Section {
                inputToggle("英文标点", .englishPunctuation)
                Group {
                    punctuationPicker("{}", mapped: "「」", option: .cornerQuotes)
                    punctuationPicker("`", mapped: "·", option: .middleDot)
                    punctuationPicker("|", mapped: "｜", option: .fullwidthPipe)
                    punctuationPicker("\\", mapped: "、", option: .ideographicComma)
                }
                .disabled(settings.inputPreferences[.englishPunctuation])
            }
            Section {
                inputToggle("繁体输入", .traditional)
            }
            if let error = settings.inputSettingsError {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.input")
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
final class SettingsHostingController: NSHostingController<SettingsView> {
    override init(rootView: SettingsView) {
        super.init(rootView: rootView)
        // Explicit AppKit constraints own sizing instead of each SwiftUI page.
        sizingOptions = []
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 700),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Settings hosts are created programmatically") }
}

@MainActor
final class IFSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let sharedController = IFSettingsWindowController(settings: .sharedSettings)
    private static let editingMenuItem: NSMenuItem = {
        let menu = NSMenu(title: "编辑")
        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }()
    var dictionaries: IFDictionaryCoordinator?

    func windowWillClose(_ notification: Notification) { dictionaries?.presentationClosed() }
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
        window.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
        window.isReleasedWhenClosed = false
        window.contentViewController = SettingsHostingController(rootView: SettingsView(settings: settings, dictionaries: dictionaries))
        window.setContentSize(NSSize(width: 700, height: 450))
        self.window = window
        window.delegate = self
        window.center()
    }

    func present() {
        dictionaries?.presentationOpened()
        if window == nil { loadWindow() }
        // The accessory app has no storyboard menu. Standard nil-target actions let
        // AppKit route editing shortcuts to the focused native or secure field editor.
        let mainMenu = NSApp.mainMenu ?? NSMenu()
        if !mainMenu.items.contains(where: { $0 === Self.editingMenuItem }) {
            Self.editingMenuItem.menu?.removeItem(Self.editingMenuItem)
            mainMenu.addItem(Self.editingMenuItem)
        }
        NSApp.mainMenu = mainMenu
        NSApp.setActivationPolicy(.accessory)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
