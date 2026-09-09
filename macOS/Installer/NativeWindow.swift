import AppKit

@MainActor final class IFInstallWindowController: NSWindowController, NSWindowDelegate {
    let heading = NSTextField(labelWithString: "")
    let summary = NSTextField(wrappingLabelWithString: "")
    let versionLabel = NSTextField(wrappingLabelWithString: "")
    let pathLabel = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    let primary = NSButton(title: "", target: nil, action: nil)
    let secondary = NSButton(title: "", target: nil, action: nil)
    let settings = NSButton(title: "打开系统设置", target: nil, action: nil)
    let diagnostics = NSButton(title: "查看诊断", target: nil, action: nil)
    let details = NSTextView()
    private let detailScroll = NSScrollView()
    private let exitLabel = NSTextField(wrappingLabelWithString: "")
    private var coordinator: IFInstallerCoordinator?
    private let makeCoordinator: @MainActor () async throws -> IFInstallerCoordinator
    private let cleanup: @MainActor () async throws -> Void
    private let openSettings: @MainActor () -> Void
    var requestExit: @MainActor () -> Void = {}
    var settled: (@MainActor () -> Void)?
    private(set) var owningTask: Task<Void, Never>?
    private(set) var state: IFInstallerState = .idle
    private(set) var exitRequested = false
    private var cancellationRequested = false
    private var loading = false
    private var primaryAction: IFInstallerAction?
    private var secondaryAction: IFInstallerAction?
    private let initialTitle: String
    private let initialSummary: String
    var busy: Bool { owningTask != nil || loading || state.busy }

    init(version: IFAppVersion, installedVersion: IFAppVersion?, target: URL,
         makeCoordinator: @escaping @MainActor () async throws -> IFInstallerCoordinator,
         cleanup: @escaping @MainActor () async throws -> Void = {},
         openSettings: @escaping @MainActor () -> Void = {
             NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
         }) {
        self.makeCoordinator = makeCoordinator; self.cleanup = cleanup; self.openSettings = openSettings
        initialTitle = "安装并启用"
        initialSummary = installedVersion == nil ? "将墨流安装到当前用户，并启用墨流拼音。" : "将检查现有版本；需要更新时会短暂切换输入法，请先结束当前输入。"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "墨流安装器"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        summary.font = .systemFont(ofSize: 14)
        [summary, versionLabel, pathLabel, exitLabel].forEach {
            $0.maximumNumberOfLines = 0; $0.lineBreakMode = .byWordWrapping
        }
        versionLabel.stringValue = "安装版本：\(version.version)（\(version.build)）" + (installedVersion.map { "    安装前版本：\($0.version)（\($0.build)）" } ?? "")
        pathLabel.stringValue = "当前用户安装位置：\n\(target.path)"
        pathLabel.isSelectable = true; pathLabel.textColor = .secondaryLabelColor
        versionLabel.isSelectable = true
        exitLabel.textColor = .secondaryLabelColor
        progress.style = .spinning; progress.controlSize = .small; progress.isIndeterminate = true
        progress.setAccessibilityLabel("安装进度")
        for button in [primary, secondary, settings, diagnostics] {
            button.bezelStyle = .rounded; button.target = self
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        primary.action = #selector(primaryClicked); secondary.action = #selector(secondaryClicked)
        settings.action = #selector(settingsClicked); diagnostics.action = #selector(diagnosticsClicked)
        primary.keyEquivalent = "\r"; secondary.keyEquivalent = "\u{1b}"
        details.isEditable = false; details.isSelectable = true
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.isHorizontallyResizable = false; details.isVerticallyResizable = true
        details.textContainer?.widthTracksTextView = true
        details.autoresizingMask = [.width]
        detailScroll.documentView = details; detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detailScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        detailScroll.isHidden = true
        let helpers = NSStackView(views: [settings, diagnostics])
        helpers.orientation = .horizontal; helpers.spacing = 8
        let buttons = NSStackView(views: [secondary, primary])
        buttons.orientation = .horizontal; buttons.spacing = 8
        let stack = NSStackView(views: [heading, versionLabel, pathLabel, summary, progress, exitLabel, helpers, detailScroll, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -26),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            versionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            exitLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
        window.center()
        render(.idle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Used by both window-close and applicationShouldTerminate, without cancelling the owner Task.
    func deferExitIfBusy() -> Bool {
        guard busy else { return false }
        exitRequested = true
        if loading || state.actions.contains(.cancel) { cancelPreparation() }
        render(state)
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestExit(); return false }
    @objc private func primaryClicked() {
        if let primaryAction { start(primaryAction) } else if !busy { requestExit() }
    }
    @objc private func secondaryClicked() {
        if secondaryAction == .cancel { cancelPreparation() }
        else if let secondaryAction { start(secondaryAction) }
        else if !busy { requestExit() }
    }
    @objc private func settingsClicked() { if !busy { openSettings() } }
    @objc private func diagnosticsClicked() {
        detailScroll.isHidden.toggle()
        diagnostics.title = detailScroll.isHidden ? "查看诊断" : "收起诊断"
        fitWindow()
    }
    private func cancelPreparation() {
        guard loading || state.actions.contains(.cancel) else { return }
        cancellationRequested = true
        if let coordinator, !loading {
            Task { await coordinator.perform(.cancel) }
        }
        secondary.isEnabled = false
    }
    private func start(_ action: IFInstallerAction) {
        guard !busy, state.actions.contains(action), !exitRequested else { return }
        cancellationRequested = false
        // Guard synchronously, before the Task gets a turn on the main actor.
        loading = action == .installAndEnable
        primary.isEnabled = false; secondary.isEnabled = false
        owningTask = Task { [self] in
            var didLoad = false
            do {
                if action == .installAndEnable {
                    render(.preparing)
                    coordinator = try await makeCoordinator()
                    didLoad = true
                    loading = false
                    if cancellationRequested { render(.cancelled) }
                    else {
                        coordinator!.stateChanged = { [weak self] in self?.render($0) }
                        await coordinator!.perform(action)
                    }
                } else if let coordinator {
                    await coordinator.perform(action)
                }
            } catch {
                loading = false
                render(.failed(installed: false, message: String(describing: error)))
            }
            // Retain the candidate until the entire perform call settles. Retries use installed code.
            if action == .installAndEnable || didLoad {
                do { try await cleanup() }
                catch {
                    details.string += "\n临时文件未清理：\(error)"
                    diagnostics.isHidden = false
                }
            }
            loading = false; owningTask = nil
            render(state, preserveDetails: true)
            settled?()
        }
    }

    func render(_ state: IFInstallerState, preserveDetails: Bool = false) {
        self.state = state
        primaryAction = nil; secondaryAction = nil
        primary.title = "完成"; primary.isHidden = false
        secondary.title = "关闭"; secondary.isHidden = false
        settings.isHidden = true
        var technical = ""
        switch state {
        case .idle, .cancelled:
            heading.stringValue = state == .idle ? "安装墨流" : "已取消安装"
            summary.stringValue = state == .idle ? initialSummary : "安装准备已取消，可以重新开始。"
            primary.title = initialTitle; primaryAction = .installAndEnable
        case .preparing:
            heading.stringValue = "正在准备安装"
            summary.stringValue = "正在检查并准备安装包，请稍候。"
            primary.isHidden = true; secondary.title = "取消"; secondaryAction = .cancel
        case .stoppingOldVersion:
            heading.stringValue = "正在更新墨流"
            summary.stringValue = "正在等待旧版本安全退出，请稍候。"
            primary.isHidden = true; secondary.isHidden = true
        case .committing:
            heading.stringValue = "正在完成安装"
            summary.stringValue = "正在替换程序，请稍候。"
            primary.isHidden = true; secondary.isHidden = true
        case .activating:
            heading.stringValue = "正在启用墨流"
            summary.stringValue = "正在启用并选择输入法，请稍候。"
            primary.isHidden = true; secondary.isHidden = true
        case .installedEnabled:
            heading.stringValue = "墨流已安装并启用"
            summary.stringValue = "已确认启用和选择，可以开始使用墨流。"
            secondary.isHidden = true
        case .installedAwaitingApproval(let message):
            heading.stringValue = "已安装，等待系统确认"
            summary.stringValue = "系统尚未确认启用或切换。请在系统设置的「键盘」中检查输入法及可能出现的确认提示，然后重试启用。"
            primary.title = "重试启用"; primaryAction = .retryActivation
            settings.isHidden = false; technical = message
        case .failed(let installed, let message):
            heading.stringValue = installed ? "已安装，启用未完成" : "安装未完成"
            summary.stringValue = installed ? "安装文件已保留，启用遇到问题。请查看诊断后重试启用。" : "准备或安装遇到问题，请查看诊断并处理后重试。"
            primary.title = installed ? "重试启用" : "重试安装"
            primaryAction = installed ? .retryActivation : .installAndEnable
            technical = message
        }
        if !preserveDetails { details.string = technical; detailScroll.isHidden = true; diagnostics.title = "查看诊断" }
        diagnostics.isHidden = details.string.isEmpty
        if diagnostics.isHidden { detailScroll.isHidden = true }
        progress.isHidden = !busy
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        primary.isEnabled = !busy && !exitRequested && (primaryAction.map { state.actions.contains($0) } ?? true)
        secondary.isEnabled = secondaryAction == .cancel ? !cancellationRequested : !busy && !exitRequested
        settings.isEnabled = !busy; diagnostics.isEnabled = !busy
        exitLabel.isHidden = !exitRequested
        exitLabel.stringValue = "已收到退出请求，将在当前操作安全结束后退出。"
        fitWindow()
    }
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = content.subviews[0].fittingSize.height + 52
        window.setContentSize(NSSize(width: 570, height: max(340, height)))
        content.layoutSubtreeIfNeeded()
    }
}

@MainActor final class IFInstallAppDelegate: NSObject, NSApplicationDelegate {
    let controller: IFInstallWindowController
    private(set) var terminationPending = false
    private let reply: @MainActor (Bool) -> Void
    init(controller: IFInstallWindowController,
         reply: @escaping @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }) {
        self.controller = controller; self.reply = reply
        super.init()
        controller.requestExit = { NSApp.terminate(nil) }
        controller.settled = { [weak self] in
            guard let self, self.terminationPending else { return }
            self.terminationPending = false
            self.reply(true)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller.deferExitIfBusy() { terminationPending = true; return .terminateLater }
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showWindow(nil); return true
    }
}
