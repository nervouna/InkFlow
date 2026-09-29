import InkFlowRime
import InkFlowDomain
import AppKit
import Combine
import SwiftUI

@MainActor
package final class IFUpdaterAccess: ObservableObject {
    private let readAutomaticChecks: @MainActor () -> Bool
    private let writeAutomaticChecks: @MainActor (Bool) -> Void
    private let readAutomaticDownloads: @MainActor () -> Bool
    private let writeAutomaticDownloads: @MainActor (Bool) -> Void
    private let readAllowsAutomaticUpdates: @MainActor () -> Bool
    private let readCanCheckForUpdates: @MainActor () -> Bool
    private let performCheckForUpdates: @MainActor () -> Void
    private let performStartUpdater: @MainActor () -> Void
    private var observations: [NSKeyValueObservation] = []
    @Published private var preferenceRevision = 0

    package init(readAutomaticChecks: @escaping @MainActor () -> Bool,
                 writeAutomaticChecks: @escaping @MainActor (Bool) -> Void,
                 readAutomaticDownloads: @escaping @MainActor () -> Bool,
                 writeAutomaticDownloads: @escaping @MainActor (Bool) -> Void,
                 readAllowsAutomaticUpdates: @escaping @MainActor () -> Bool,
                 readCanCheckForUpdates: @escaping @MainActor () -> Bool,
                 performCheckForUpdates: @escaping @MainActor () -> Void,
                 performStartUpdater: @escaping @MainActor () -> Void) {
        self.readAutomaticChecks = readAutomaticChecks
        self.writeAutomaticChecks = writeAutomaticChecks
        self.readAutomaticDownloads = readAutomaticDownloads
        self.writeAutomaticDownloads = writeAutomaticDownloads
        self.readAllowsAutomaticUpdates = readAllowsAutomaticUpdates
        self.readCanCheckForUpdates = readCanCheckForUpdates
        self.performCheckForUpdates = performCheckForUpdates
        self.performStartUpdater = performStartUpdater
    }

    package var automaticallyChecksForUpdates: Bool {
        get { readAutomaticChecks() }
        set { writeAutomaticChecks(newValue) }
    }

    package var automaticallyDownloadsUpdates: Bool {
        get { readAutomaticDownloads() }
        set { writeAutomaticDownloads(newValue) }
    }

    package var allowsAutomaticUpdates: Bool { readAllowsAutomaticUpdates() }
    package var canCheckForUpdates: Bool { readCanCheckForUpdates() }
    package func checkForUpdates() { performCheckForUpdates() }
    package func startUpdater() { performStartUpdater() }

    package func retainObservation(_ observation: NSKeyValueObservation) {
        observations.append(observation)
    }

    package func updaterPreferencesDidChange() {
        preferenceRevision &+= 1
    }
}

package enum IFUpdateDiagnosticOutcome: Sendable {
    case begin, ready, completed, failed, cancelled, skipped, handled
}

package enum IFUpdateDiagnostics {
    package static func record(event: StaticString, outcome: IFUpdateDiagnosticOutcome,
                               reason: StaticString? = nil, correlation: UUID?,
                               elapsedMilliseconds: Double? = nil, error: (any Error)? = nil) {
        let diagnosticOutcome: LocalDiagnosticEvent.Outcome = switch outcome {
        case .begin: .begin
        case .ready: .ready
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .skipped: .skipped
        case .handled: .handled
        }
        let safeError = error.map(LocalDiagnosticEvent.safeError)
        LocalDiagnostics.shared.submit(.init(module: .update, event: event, outcome: diagnosticOutcome,
            reason: reason, correlation: correlation, elapsedMilliseconds: elapsedMilliseconds,
            errorDomain: safeError?.0, errorCode: safeError?.1))
    }
}

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
    let shortcuts: KeyboardShortcuts
    let smart: IFSmartSettings
    let voice: VoicePreparation
    private(set) var customPhrases: [CustomPhrase] = []
    private(set) var customPhrasesLoadError: String?
    private(set) var voicePolishRules: [VoicePolishRule] = []
    private(set) var voicePolishRulesLoadError: String?
    @Published var inputSettingsError: String?
    @Published var personalDataRecoveryRequired = false
    @Published var personalDataApplying = false
    var personalDataWriteBlocked: Bool { personalDataRecoveryRequired || personalDataApplying }
    var qualityStore: QualityStore?
    @Published private(set) var qualityCommandPending = false
    @Published private(set) var qualityControlMessage: String?

    var qualityRecordingPaused: Bool { integer(for: "qualityRecordingPaused", allowed: [0, 1], fallback: 0) != 0 }
    var qualityRecordingStatus: String {
        guard qualityStore != nil else { return "未启动" }
        if qualityStore?.statistics().disabled == true { return "本次记录不可用" }
        return qualityRecordingPaused ? "已暂停" : "已开启"
    }

    func setQualityRecordingPaused(_ paused: Bool) async {
        guard !qualityCommandPending, let qualityStore else { return }
        qualityCommandPending = true
        qualityControlMessage = nil
        // Preserve the user's choice even if the optional writer has failed for this launch.
        objectWillChange.send()
        defaults.set(paused ? 1 : 0, forKey: "qualityRecordingPaused")
        defer { qualityCommandPending = false }
        do {
            try await qualityStore.setPaused(paused)
            qualityControlMessage = paused ? "已暂停记录。正在输入的内容不会补记。" : "已恢复记录，从下一段新输入开始。"
        } catch { qualityControlMessage = "记录设置已保存，但本次操作未完成。请重新启动墨流后检查。" }
    }

    func clearQualityRecords() async {
        guard !qualityCommandPending, let qualityStore else { return }
        qualityCommandPending = true
        qualityControlMessage = nil
        defer { qualityCommandPending = false }
        do {
            try await qualityStore.clearRecords()
            qualityControlMessage = "已清除全部质量记录。记录开关保持不变。"
        } catch { qualityControlMessage = "清除未完成，原有记录可能仍然保留。请稍后重试。" }
    }

    init(defaults: UserDefaults, aiCredentials: any AICredentialStore = MemoryAICredentialStore(),
         voiceService: any VoiceRecognitionServing = AppleVoiceRecognizer()) {
        self.defaults = defaults
        shortcuts = KeyboardShortcuts(defaults: defaults)
        voice = VoicePreparation(service: voiceService)
        smart = IFSmartSettings(defaults: defaults, credentials: aiCredentials)
        loadCustomPhrases()
        loadVoicePolishRules()
    }

    private func loadCustomPhrases() {
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

    private func loadVoicePolishRules() {
        guard let stored = defaults.object(forKey: "voicePolishRules") else { return }
        do {
            guard let data = stored as? Data else { throw VoicePolishRuleError("数据格式无效。") }
            let rules = try JSONDecoder().decode([VoicePolishRule].self, from: data)
            try VoicePolishRule.validate(rules)
            voicePolishRules = rules
        } catch {
            voicePolishRulesLoadError = "无法读取已保存的语音润色规则，原数据已保留。请先恢复偏好设置的备份。"
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
        guard !personalDataWriteBlocked else { throw PersonalDataError("recovery-required") }
        if let customPhrasesLoadError { throw CustomPhraseError(customPhrasesLoadError) }
        try CustomPhrase.validate(phrases)
        let data = try JSONEncoder().encode(phrases)
        objectWillChange.send()
        defaults.set(data, forKey: "customPhrases")
        customPhrases = phrases
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
    }

    @discardableResult
    func saveVoicePolishRule(originalBundleIdentifier: String? = nil, bundleIdentifier: String,
                             displayName: String, isEnabled: Bool, prompt: String) throws -> VoicePolishRule {
        let rule = try VoicePolishRule.validated(bundleIdentifier: bundleIdentifier, displayName: displayName,
                                                 isEnabled: isEnabled, prompt: prompt)
        var updated = voicePolishRules
        if let originalBundleIdentifier {
            guard let index = updated.firstIndex(where: { $0.bundleIdentifier == originalBundleIdentifier }) else {
                throw VoicePolishRuleError("要编辑的应用规则已不存在。")
            }
            updated[index] = rule
        } else {
            updated.append(rule)
        }
        try persistVoicePolishRules(updated)
        return rule
    }

    func setVoicePolishRuleEnabled(bundleIdentifier: String, enabled: Bool) throws {
        guard let rule = voicePolishRules.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw VoicePolishRuleError("要修改的应用规则已不存在。")
        }
        guard rule.isEnabled != enabled else { return }
        _ = try saveVoicePolishRule(originalBundleIdentifier: bundleIdentifier,
            bundleIdentifier: rule.bundleIdentifier, displayName: rule.displayName,
            isEnabled: enabled, prompt: rule.prompt)
    }

    func deleteVoicePolishRule(bundleIdentifier: String) throws {
        guard voicePolishRules.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw VoicePolishRuleError("要删除的应用规则已不存在。")
        }
        try persistVoicePolishRules(voicePolishRules.filter { $0.bundleIdentifier != bundleIdentifier })
    }

    func enabledVoicePolishRule(for bundleIdentifier: String) -> VoicePolishRule? {
        VoicePolishRule.enabledRule(in: voicePolishRules, matching: bundleIdentifier)
    }

    private func persistVoicePolishRules(_ rules: [VoicePolishRule]) throws {
        guard !personalDataWriteBlocked else { throw PersonalDataError("recovery-required") }
        if let voicePolishRulesLoadError { throw VoicePolishRuleError(voicePolishRulesLoadError) }
        try VoicePolishRule.validate(rules)
        let data = try JSONEncoder().encode(rules)
        objectWillChange.send()
        defaults.set(data, forKey: "voicePolishRules")
        voicePolishRules = rules
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
    }

    private func integer(for key: String, allowed: [Int], fallback: Int) -> Int {
        guard let value = defaults.object(forKey: key) as? NSNumber,
              allowed.contains(where: { value == NSNumber(value: $0) }) else { return fallback }
        return value.intValue
    }

    func personalBackupSettings() throws -> PersonalBackupSettings {
        guard customPhrasesLoadError == nil, voicePolishRulesLoadError == nil else { throw PersonalDataError("unreadable-settings") }
        var integers = ["candidateCount": candidateCount, "fontSize": fontSize, "vertical": vertical ? 1 : 0, "thunderMode": thunderMode ? 1 : 0]
        for option in InputOption.allCases { integers["input.\(option.rawValue)"] = inputPreferences[option] ? 1 : 0 }
        let snapshot = PersonalBackupSettings(integers: integers,
            shortcuts: Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, shortcuts.binding(for: $0)) }),
            phrases: customPhrases, voiceRules: voicePolishRules)
        try snapshot.validate()
        return snapshot
    }

    func personalRollbackPreferences() async throws -> [String: Data] {
        let store = PersonalDefaults(defaults: defaults)
        return try await Task.detached(priority: .utility) { try store.rollbackPreferences() }.value
    }
    func synchronizePersonalPreferences() async -> Bool {
        let store = PersonalDefaults(defaults: defaults)
        return await Task.detached(priority: .utility) { store.synchronize() }.value
    }

    func applyPersonalPreferences(_ preferences: [String: Data]) throws {
        try Self.writePersonalPreferences(preferences, defaults: defaults)
        objectWillChange.send()
        customPhrases = []; voicePolishRules = []
        customPhrasesLoadError = nil; voicePolishRulesLoadError = nil
        loadCustomPhrases(); loadVoicePolishRules(); shortcuts.reloadBackupBindings()
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
    }

    static func writePersonalPreferences(_ preferences: [String: Data], defaults: UserDefaults) throws {
        guard Set(preferences.keys).isSubset(of: PersonalBackupSettings.keys) else { throw PersonalDataError("preferences") }
        let decoded = try preferences.mapValues { try PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
        for key in PersonalBackupSettings.keys {
            if let value = decoded[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        // The committed journal remains authoritative until the next process startup.
    }

    private func set(_ value: Int, for key: String) {
        guard !personalDataWriteBlocked else { return }
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
    @discardableResult
    func migrateLegacyAutomaticUpdateChecks(to updater: IFUpdaterAccess) -> Bool? {
        let migrationKey = "sparkleAutomaticChecksMigrationCompleted"
        guard defaults.object(forKey: migrationKey) == nil else { return nil }

        let legacyValue = defaults.object(forKey: "automaticUpdateChecksEnabled") as? NSNumber
        let migratedValue = legacyValue == NSNumber(value: 1)
        updater.automaticallyChecksForUpdates = migratedValue
        updater.automaticallyDownloadsUpdates = false
        defaults.set(true, forKey: migrationKey)
        return migratedValue
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
        guard !personalDataWriteBlocked else { return }
        guard values.contains(where: { inputValue($0.key) != $0.value }) else { return }
        objectWillChange.send()
        for (option, enabled) in values { defaults.set(enabled, forKey: "input.\(option.rawValue)") }
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case input = "输入"
    case shortcuts = "快捷键"
    case appearance = "外观"
    case personalization = "自定义短语"
    case dictionaries = "词库"
    case voice = "语音"
    case smart = "AI 服务"
    case updates = "更新"
    case personalData = "数据"
    case feedback = "反馈与诊断"
    case about = "关于"
    static let groups: [(title: String, sections: [Self])] = [
        ("输入体验", [.input, .shortcuts, .appearance]),
        ("语言与辅助", [.personalization, .dictionaries, .voice, .smart]),
        ("应用", [.personalData, .updates, .feedback, .about])
    ]
    static var defaultSection: Self { groups[0].sections[0] }
    var id: Self { self }
    var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .input: "text.cursor"
        case .shortcuts: "keyboard"
        case .personalization: "person.crop.circle"
        case .smart: "sparkles"
        case .voice: "mic"
        case .dictionaries: "books.vertical"
        case .updates: "arrow.triangle.2.circlepath"
        case .personalData: "externaldrive"
        case .feedback: "exclamationmark.bubble"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: IFSettings
    var dictionaries: IFDictionaryCoordinator?
    var updaterAccess: IFUpdaterAccess?
    let feedbackReporter: FeedbackReporter
    let diagnosticDependencies: DiagnosticFeedbackDependencies
    @State private var section: SettingsSection?

    init(settings: IFSettings, dictionaries: IFDictionaryCoordinator? = nil,
         updaterAccess: IFUpdaterAccess? = nil,
         initialSection: SettingsSection = .defaultSection, feedbackReporter: FeedbackReporter = .live,
         diagnosticDependencies: DiagnosticFeedbackDependencies = .live) {
        self.settings = settings
        self.dictionaries = dictionaries
        self.updaterAccess = updaterAccess
        self.feedbackReporter = feedbackReporter
        self.diagnosticDependencies = diagnosticDependencies
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SettingsSection.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label(section.rawValue, systemImage: section.symbol)
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("墨流拼音设置")
            .accessibilityIdentifier("settings.sidebar")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 210)
        } detail: {
            Group {
                if section == .about { AboutSettingsView() }
                else if section == .feedback { FeedbackSettingsView(reporter: feedbackReporter, diagnosticDependencies: diagnosticDependencies) }
                else if section == .personalData { PersonalDataSettingsView(settings: settings, coordinator: dictionaries) }
                else if section == .appearance { appearance }
                else if section == .shortcuts { ShortcutsSettingsView(shortcuts: settings.shortcuts) }
                else if section == .personalization { CustomPhrasesView(settings: settings) }
                else if section == .smart { SmartSettingsView(settings: settings, smart: settings.smart) }
                else if section == .voice { VoiceSettingsView(settings: settings, shortcuts: settings.shortcuts, showShortcuts: { section = .shortcuts }, showAIService: { section = .smart }) }
                else if section == .dictionaries { DictionarySettingsView(coordinator: dictionaries) }
                else if section == .updates {
                    if let updaterAccess { UpdateSettingsView(updaterAccess: updaterAccess) }
                    else { EmptyView() }
                }
                else { input }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .navigationTitle((section ?? .defaultSection).rawValue)
        }
        .navigationSplitViewStyle(.balanced)
        .disabled(settings.personalDataWriteBlocked)
        .overlay {
            if settings.personalDataRecoveryRequired { Text("个人数据恢复尚未完成。请退出并重新启动墨流后再修改设置。").padding().background(.regularMaterial) }
        }
    }

    private var appearance: some View {
        Form {
            Section {
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
            Section {
                Toggle("庆祝模式", isOn: $settings.thunderMode)
                    .help("每次输入和上屏时在光标处绽放彩花")
                    .accessibilityLabel("庆祝模式")
                    .accessibilityIdentifier("settings.thunderMode")
            }
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

}

@MainActor
final class SettingsHostingController: NSHostingController<SettingsView> {
    override init(rootView: SettingsView) {
        super.init(rootView: rootView)
        // Explicit AppKit constraints own sizing instead of each SwiftUI page.
        sizingOptions = []
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 700),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 600),
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
    var updaterAccess: IFUpdaterAccess?

    func windowWillClose(_ notification: Notification) {
        dictionaries?.presentationClosed()
        if IFPersonalLearningWindowController.sharedController.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    private let settings: IFSettings

    init(settings: IFSettings, updaterAccess: IFUpdaterAccess? = nil) {
        self.settings = settings
        self.updaterAccess = updaterAccess
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError("Settings windows are created programmatically") }

    override func loadWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "墨流拼音设置"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
        window.isReleasedWhenClosed = false
        window.contentViewController = SettingsHostingController(rootView: SettingsView(
            settings: settings, dictionaries: dictionaries, updaterAccess: updaterAccess
        ))
        window.setContentSize(NSSize(width: 700, height: 600))
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
        // TCC can return focus to another app when an accessory app's permission
        // alert closes. Keep Settings a regular window, including Dock/Cmd-Tab
        // reachability, until it closes; ordinary input remains accessory-only.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
