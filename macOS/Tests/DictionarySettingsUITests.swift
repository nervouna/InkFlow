import AppKit
import SwiftUI
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowNativeTestSupport
import InkFlowTestSupport
#endif

private final class DictionaryUIBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

@MainActor enum DictionarySettingsUITests {
    static func run(settings: IFSettings, shared: URL, root: URL) async throws {
        let preferences = IFSettingsWindowController(settings: settings)
        preferences.present()
        let window = preferences.window!
        await show(window, settings: settings, service: nil)
        checkText("dictionaries.state", contains: "正在准备词库", in: window)
        check(actions(in: window).isEmpty, "Unconfigured Dictionary settings must not offer an action")
        window.close()

        let runtime = IFDictionaryRuntime.bundled(helper: shared.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacOS/InkFlowDictionaryWorker"))
        let store = try IFDictionaryStore(root: root.appendingPathComponent("Dictionaries"))
        let worker = IFDictionaryWorkerRunner(runtime: runtime, protectedUserRoot: root,
            candidatesRoot: store.root.appendingPathComponent("candidates"))
        let manifest = try store.bundled(shared).manifest
        let fault = DictionaryUIBox<IFDictionaryUpdateError?>(nil)
        let changed = DictionaryUIBox(true)
        let delay = DictionaryUIBox(false)
        let prepared = DictionaryUIBox(false)
        let fingerprint = try runtime.fingerprint()
        var services = IFDictionaryServices(client: .init(), worker: worker)
        services.check = { _ in
            if delay.value { try await Task.sleep(for: .milliseconds(700)) }
            if let failure = fault.value, failure.stage == .check { throw failure }
            return .init(sources: [], hasUpdate: changed.value)
        }
        services.download = { _, progress in
            progress(.init(stage: .download, completed: 1, total: 6))
            if delay.value { try await Task.sleep(for: .milliseconds(500)) }
            if let failure = fault.value, failure.stage == .download { throw failure }
            return []
        }
        services.prepare = { candidate, _, _, progress in
            progress(.init(stage: .prepare, completed: 1, total: 2))
            guard prepared.value else { return .init(outcome: .contentUnchanged, manifest: manifest) }
            return try await Task.detached {
                try FileManager.default.copyItem(at: shared, to: candidate.appendingPathComponent("shared"))
                try FileManager.default.copyItem(at: root.appendingPathComponent("build"), to: candidate.appendingPathComponent("cache"))
                let receipt = IFDictionaryPreparedReceipt(contentVersion: manifest.contentVersion,
                    runtimeFingerprint: fingerprint, files: try IFDictionaryFiles.hashes(in: candidate))
                try IFDictionaryFiles.encode(receipt).write(to: candidate.appendingPathComponent(IFDictionaryPreparedReceipt.filename))
                return .init(outcome: .prepared, manifest: manifest)
            }.value
        }
        let service = IFDictionaryCoordinator(backend: .init(store: store, runtime: runtime, user: root, services: services))
        service.bootstrap()
        check(service.engineAvailable && service.active?.manifest == manifest)
        preferences.dictionaries = service
        preferences.present()
        await show(window, settings: settings, service: service)

        checkText("dictionaries.state", contains: "词库已启用", in: window)
        checkText("dictionaries.count", contains: manifest.entryCount.formatted(), in: window)
        checkText("dictionaries.engineStatus", contains: "随 InkFlow 提供", in: window)
        check(actions(in: window) == ["检查词库更新"], "Ready state must offer only Check for Updates")
        check(element("dictionaries.version", in: window) == nil && disclosure("词库来源", in: window) == nil,
              "Dictionary settings must omit technical version and source details")
        await fit(window, required: ["dictionaries.state", "dictionaries.count", "dictionaries.check"])

        delay.value = true
        await press("dictionaries.check", in: window)
        await until("Checking began") { service.activity == .checking }
        checkText("dictionaries.status", contains: "正在检查词库更新", in: window)
        check(actions(in: window).isEmpty, "Busy state must not offer a duplicate action")
        await until("Check finished") { !service.isBusy }
        checkText("dictionaries.status", contains: "发现词库更新", in: window)
        check(actions(in: window) == ["更新词库"], "Available state must offer only Update Dictionary")

        await press("dictionaries.update", in: window)
        await until("Download began") { service.activity == .downloading }
        checkText("dictionaries.status", contains: "正在更新词库", in: window)
        check(actions(in: window).isEmpty, "Updating state must not offer another action")
        await until("Unchanged update finished") { !service.isBusy }
        checkText("dictionaries.status", contains: "词库已是最新", in: window)
        check(actions(in: window) == ["检查词库更新"], "Up-to-date state must return to one check action")

        delay.value = false
        changed.value = true
        await press("dictionaries.check", in: window)
        await until("Update became available") { service.canUpdate }
        fault.value = error(.download)
        await press("dictionaries.update", in: window)
        await until("Download failed") { !service.isBusy }
        checkText("dictionaries.failure", contains: "更新失败", in: window)
        checkText("dictionaries.failureMessage", contains: "当前词库仍可正常使用", in: window)
        check(actions(in: window) == ["重试"], "Recoverable failure must offer only Retry")
        await verifyDetails(window, failure: service.failure!)

        fault.value = nil
        prepared.value = true
        let engine = IFEngine()!
        type(engine, "nihao")
        await press("dictionaries.retry", in: window)
        await until("Waiting for composition") { service.activity == .waitingForIdle }
        checkText("dictionaries.status", contains: "当前输入结束后启用", in: window)
        check(actions(in: window).isEmpty, "Waiting state must not offer another action")
        engine.clear()
        await until("Update activated") { !service.isBusy }
        checkText("dictionaries.status", contains: "词库已更新并启用", in: window)

        await press("dictionaries.check", in: window)
        await until("Apply update became available") { service.canUpdate }
        service.activationFault = { step, rollback in
            if step == .probe { throw error(rollback ? .rollback : .apply) }
        }
        await press("dictionaries.update", in: window)
        await until("Apply and rollback failed") { !service.isBusy }
        check(!service.engineAvailable)
        checkText("dictionaries.failure", contains: "词库暂不可用", in: window)
        checkText("dictionaries.failureMessage", contains: "请恢复后继续输入", in: window)
        check(actions(in: window) == ["恢复词库"], "Unavailable state must offer only Restore Dictionary")

        window.close()
        preferences.present()
        await show(window, settings: settings, service: service)
        check(service.failure == nil && !service.engineAvailable)
        checkText("dictionaries.state", contains: "词库暂不可用", in: window)
        check(actions(in: window) == ["恢复词库"],
              "Unavailable state must retain Restore Dictionary after dismissing its diagnostic")

        service.activationFault = { _, _ in }
        await press("dictionaries.retry", in: window)
        await until("Dictionary recovered") { service.engineAvailable && !service.isBusy }
        check(service.failure == nil)
        window.close()
        IFEngine.stop()
        print("PASS dictionary settings UI: ready, available, busy, recoverable failure and unavailable recovery states each expose one clear action")
    }

    nonisolated static func error(_ stage: IFDictionaryStage) -> IFDictionaryUpdateError {
        .init(stage, "synthetic-\(stage.rawValue)", source: "frost-base", file: "cn_dicts/base.dict.yaml",
              httpStatus: 429, exitStatus: 17, detail: "NSURLErrorDomain (-1009)",
              stderr: String(repeating: "synthetic worker diagnostic line 中文 0123456789\n", count: 20))
    }

    static func verifyDetails(_ window: NSWindow, failure: IFDictionaryUpdateError) async {
        await pressDisclosure("查看错误详情", in: window)
        check(text("dictionaries.errorDetails", in: window).contains(failure.technicalDetails),
              "Full diagnostic must remain accessible and selectable")
        await pressDisclosure("查看错误详情", in: window)
    }

    static func show(_ window: NSWindow, settings: IFSettings, service: IFDictionaryCoordinator?) async {
        window.contentViewController = SettingsHostingController(rootView: SettingsView(
            settings: settings, dictionaries: service, initialSection: .dictionaries))
        try? await Task.sleep(for: .milliseconds(200))
        drainEvents()
        SettingsUITests.checkMinimumSize(window)
    }

    static func element(_ identifier: String, in window: NSWindow) -> [String: Any]? {
        window.contentView?.layoutSubtreeIfNeeded()
        let matches = IFAccessibilityTree(window).filter { $0["id"] as? String == identifier }
        check(matches.count <= 1, "Duplicate accessibility identifier \(identifier): \(matches.count) matches")
        return matches.first
    }

    static func disclosure(_ label: String, in window: NSWindow) -> [String: Any]? {
        IFAccessibilityTree(window).first {
            $0["role"] as? String == "AXDisclosureTriangle" && $0["label"] as? String == label
        }
    }

    static func text(_ identifier: String, in window: NSWindow) -> String {
        drainEvents(seconds: 0.02)
        guard let element = element(identifier, in: window) else {
            check(false, "Missing accessible text \(identifier)")
            return ""
        }
        return "\(element["label"] ?? "") \(element["value"] ?? "")"
    }

    static func checkText(_ identifier: String, contains expected: String, in window: NSWindow) {
        let actual = text(identifier, in: window)
        check(actual.contains(expected), "\(identifier): expected \(expected), got \(actual)")
    }

    static func actions(in window: NSWindow) -> [String] {
        ["dictionaries.check", "dictionaries.update", "dictionaries.retry"].compactMap { identifier in
            element(identifier, in: window)?["label"] as? String
        }
    }

    static func press(_ identifier: String, in window: NSWindow) async {
        let pressed = element(identifier, in: window) != nil && IFPressAccessibility(window, identifier)
        check(pressed, "Native AX press \(identifier)")
        try? await Task.sleep(for: .milliseconds(50))
        drainEvents(seconds: 0.02)
    }

    static func pressDisclosure(_ label: String, in window: NSWindow) async {
        let before = (disclosure(label, in: window)?["value"] as? NSNumber)?.boolValue
        check(before != nil, "Native disclosure \(label) must expose its expanded state")
        check(IFPressAccessibilityDisclosure(window, label), "Native AX disclosure press \(label)")
        let deadline = Date().addingTimeInterval(2)
        while (disclosure(label, in: window)?["value"] as? NSNumber)?.boolValue == before, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            drainEvents(seconds: 0.02)
        }
        check((disclosure(label, in: window)?["value"] as? NSNumber)?.boolValue == !before!,
              "Native disclosure \(label) must toggle its expanded state")
    }

    static func fit(_ window: NSWindow, required: [String]) async {
        for size in [NSSize(width: 700, height: 380), NSSize(width: 700, height: 700)] {
            window.setContentSize(size)
            try? await Task.sleep(for: .milliseconds(50))
            drainEvents()
            let frame = window.convertToScreen(window.contentLayoutRect)
            for identifier in required {
                guard let control = (element(identifier, in: window)?["frame"] as? NSValue)?.rectValue else {
                    check(false, "Missing accessible \(identifier)")
                    continue
                }
                check(control.width > 0 && control.height > 0 && frame.contains(control),
                      "\(identifier) must fit at \(size)")
            }
        }
    }

    static func until(_ message: String, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(90)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        check(predicate(), message)
        try? await Task.sleep(for: .milliseconds(50))
        drainEvents(seconds: 0.03)
    }
}
