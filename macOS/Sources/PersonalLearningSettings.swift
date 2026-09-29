import InkFlowRime
import SwiftUI
import AppKit

struct PersonalLearningSettingsView: View {
    var coordinator: IFDictionaryCoordinator?
    @State private var confirmClearLearning = false
    @State private var entries: [IFEngine.PersonalLearningEntry] = []
    @State private var source = IFEngine.PersonalLearningEntry.Source.english
    @State private var query = ""
    @State private var loaded = false
    @State private var message: String?
    @State private var pendingDeletion: IFEngine.PersonalLearningEntry?
    @State private var confirmDelete = false
    @State private var undo: IFEngine.PersonalLearningUndo?

    private var filtered: [IFEngine.PersonalLearningEntry] {
        entries.filter { $0.source == source && (query.isEmpty
            || $0.text.localizedCaseInsensitiveContains(query) || $0.code.localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("来源", selection: $source) {
                Text("个人英文").tag(IFEngine.PersonalLearningEntry.Source.english)
                Text("语音纠正别名").tag(IFEngine.PersonalLearningEntry.Source.voice)
            }.pickerStyle(.segmented)
            HStack {
                TextField("搜索词条或编码", text: $query)
                    .accessibilityIdentifier("learning.search")
                Button("刷新", action: reload).accessibilityIdentifier("learning.refresh")
            }
            if loaded {
                if filtered.isEmpty {
                    Text(query.isEmpty ? "此来源暂无个人学习条目。" : "没有匹配的条目。")
                        .foregroundStyle(.secondary)
                } else {
                    List(filtered) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.text).textSelection(.enabled)
                                Text("\(entry.code) · 学习 \(entry.commits) 次").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("删除", role: .destructive) { pendingDeletion = entry; confirmDelete = true }
                                .accessibilityLabel("删除 \(entry.text)，编码 \(entry.code)")
                        }
                    }.frame(minHeight: 150, maxHeight: .infinity)
                }
            }
            if let message { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("learning.status") }
            if undo != nil {
                Button("撤销上次删除", action: restore).accessibilityIdentifier("learning.undo")
            }
            Spacer(minLength: 0)
            Button("清除英文学习记录", role: .destructive) { confirmClearLearning = true }
                .accessibilityIdentifier("dictionaries.clearEnglishLearning")
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360, alignment: .topLeading)
        .disabled(coordinator?.engineAvailable != true || coordinator?.isBusy == true)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === IFPersonalLearningWindowController.sharedController.window else { return }
            reload()
        }
        .confirmationDialog("清除英文学习记录？", isPresented: $confirmClearLearning) {
            Button("清除", role: .destructive, action: clearLearning)
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除此学习条目？", isPresented: $confirmDelete) {
            if let entry = pendingDeletion {
                Button("删除", role: .destructive) { remove(entry) }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let entry = pendingDeletion {
                Text("\(entry.code) → \(entry.text)")
            }
        }
    }

    private func clearLearning() {
        let cleared = IFEngine.clearPersonalEnglishLearning()
        if cleared { undo = nil }
        reload()
        message = cleared ? "英文学习记录已清除。" : "暂时无法清除，请结束当前输入后重试。"
    }

    private func reload() {
        do {
            entries = try IFEngine.personalLearningEntries()
            loaded = true
            message = nil
        } catch { entries = []; loaded = false; message = description(error) }
    }

    private func remove(_ entry: IFEngine.PersonalLearningEntry) {
        pendingDeletion = nil
        do {
            undo = try IFEngine.deletePersonalLearning(entry)
            reload()
            if loaded { message = "条目已删除。" }
        } catch { undo = nil; reload(); message = description(error) }
    }

    private func restore() {
        guard let undo else { return }
        do {
            try IFEngine.undoPersonalLearning(undo)
            self.undo = nil
            reload()
            if loaded { message = "条目已恢复。" }
        } catch {
            if error as? IFEngine.PersonalLearningError != .busy { self.undo = nil }
            reload()
            message = description(error)
        }
    }

    private func description(_ error: Error) -> String {
        switch error as? IFEngine.PersonalLearningError {
        case .busy: "请结束当前输入，稍候几秒后刷新或重试。"
        case .conflict: "学习记录已变化，未执行此操作。请刷新后重试。"
        case .tooLarge: "条目数量或学习次数超过本次操作上限，未执行操作。"
        default: "无法读取或更新学习记录，请刷新后重试。"
        }
    }
}

@MainActor
final class IFPersonalLearningWindowController: NSWindowController, NSWindowDelegate {
    static let sharedController = IFPersonalLearningWindowController(window: nil)

    func present(coordinator: IFDictionaryCoordinator?) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "个人学习管理"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 480, height: 360)
            window.contentViewController = NSHostingController(
                rootView: PersonalLearningSettingsView(coordinator: coordinator))
            window.delegate = self
            self.window = window
            window.center()
        }
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if IFSettingsWindowController.sharedController.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
