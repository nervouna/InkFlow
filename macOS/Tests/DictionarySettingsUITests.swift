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
    func update(_ body: (inout Value) -> Void) { lock.lock(); body(&storage); lock.unlock() }
}

@MainActor enum DictionarySettingsUITests {
    static func run(settings: IFSettings, shared: URL, root: URL) async throws {
        let preferences = IFSettingsWindowController(settings: settings)
        preferences.present()
        let window = preferences.window!
        await show(.dictionaries, window: window, settings: settings, service: nil)
        if element("dictionaries.check", in: window) == nil {
            for item in IFAccessibilityTree(window) { print("AX dictionary \(item)") }
        }
        check(element("dictionaries.check", in: window)?["enabled"] as? Bool == false,
              "Unconfigured settings harness is inert")
        check(element("dictionaries.version", in: window) == nil)
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
        let calls = DictionaryUIBox((check: 0, download: 0, prepare: 0))
        let logs = DictionaryUIBox<[IFDictionaryUpdateError]>([])
        let date = DictionaryUIBox(Date(timeIntervalSince1970: 1_700_000_000))
        let progressStage = DictionaryUIBox(IFDictionaryStage.prepare)
        let fingerprint = try runtime.fingerprint()
        var services = IFDictionaryServices(client: .init(), worker: worker)
        services.check = { _ in
            calls.update { $0.check += 1 }
            if delay.value { try await Task.sleep(for: .milliseconds(700)) }
            if let failure = fault.value, failure.stage == .check { throw failure }
            return .init(sources: [], hasUpdate: changed.value)
        }
        services.download = { _, progress in
            calls.update { $0.download += 1 }
            progress(.init(stage: .download, completed: 1, total: 6))
            if delay.value { try await Task.sleep(for: .milliseconds(500)) }
            if let failure = fault.value, failure.stage == .download { throw failure }
            return []
        }
        services.prepare = { candidate, _, _, progress in
            calls.update { $0.prepare += 1 }
            progress(.init(stage: progressStage.value, completed: 1, total: 2))
            if delay.value { try await Task.sleep(for: .milliseconds(500)) }
            if let failure = fault.value { throw failure }
            guard prepared.value else { return .init(outcome: .contentUnchanged, manifest: manifest) }
            // Reuse immutable bundled data and this fixture's already compiled cache. No network/helper rerun.
            return try await Task.detached {
                try FileManager.default.copyItem(at: shared, to: candidate.appendingPathComponent("shared"))
                try FileManager.default.copyItem(at: root.appendingPathComponent("build"), to: candidate.appendingPathComponent("cache"))
                let receipt = IFDictionaryPreparedReceipt(contentVersion: manifest.contentVersion,
                    runtimeFingerprint: fingerprint, files: try IFDictionaryFiles.hashes(in: candidate))
                try IFDictionaryFiles.encode(receipt).write(to: candidate.appendingPathComponent(IFDictionaryPreparedReceipt.filename))
                return .init(outcome: .prepared, manifest: manifest)
            }.value
        }
        let service = IFDictionaryCoordinator(backend: .init(store: store, runtime: runtime, user: root, services: services),
            now: { date.value }, logger: { failure in logs.update { $0.append(failure) } })
        service.bootstrap()
        check(service.engineAvailable && service.active?.manifest == manifest)
        preferences.dictionaries = service
        preferences.present()
        await show(.dictionaries, window: window, settings: settings, service: service)
        check(text("dictionaries.version", in: window).contains(manifest.contentVersion), "Full version is accessible")
        check(text("dictionaries.count", in: window).contains(manifest.entryCount.formatted()))
        checkText("dictionaries.count", contains: "中文词条数", in: window)
        checkText("dictionaries.coverage", contains: "默认启用", in: window)
        checkText("dictionaries.updateScope", contains: "Rime 转换仓库", in: window)
        checkText("dictionaries.appUpdates", contains: "随应用更新", in: window)
        let activationLabel = text("dictionaries.activatedAt", in: window)
        await fit(window, required: ["dictionaries.check", "dictionaries.version"], disclosures: ["词库来源"])
        await pressDisclosure("词库来源", in: window)
        for spec in IFDictionaryCatalog.sources {
            checkText("dictionaries.source.\(spec.id)", contains: spec.name, in: window)
            checkText("dictionaries.commit.\(spec.id)", contains: spec.pinnedCommit, in: window)
            checkText("dictionaries.url.\(spec.id)", contains: spec.sourceURL(commit: spec.pinnedCommit).absoluteString, in: window)
        }
        await fit(window, required: ["dictionaries.check"])
        checkText("dictionaries.curatedSources", contains: "科技英文", in: window)
        check(element("dictionaries.englishSource", in: window) != nil)
        print("PASS dictionary UI metadata: Chinese content/count/activation, default domain coverage and update scope, trusted immutable sources, full versions/URLs, minimum/enlarged layout")

        delay.value = true
        await press("dictionaries.check", in: window)
        service.checkForUpdates()
        await until("Checking began") { calls.value.check == 1 }
        check(service.isBusy && element("dictionaries.check", in: window)?["enabled"] as? Bool == false)
        check(text("dictionaries.status", in: window).contains("正在检查"))
        window.close()
        check(!service.isPresented && service.isBusy)
        preferences.present()
        check(service.isPresented && service.isBusy && preferences.window === window)
        await until("Check finished") { !service.isBusy }
        check(calls.value.check == 1 && calls.value.download == 0 && service.canUpdate)
        check(text("dictionaries.status", in: window).contains("发现词库更新"))
        await fit(window, required: ["dictionaries.check", "dictionaries.update"])

        for stage in [IFDictionaryStage.download, .prepare, .verify] {
            fault.value = error(stage)
            progressStage.value = stage == .verify ? .verify : .prepare
            await press("dictionaries.update", in: window)
            await until("Download progress") { service.activity == .downloading }
            check(text("dictionaries.status", in: window).contains("正在下载"))
            if stage != .download {
                await until("Preparation progress") { service.activity == (stage == .verify ? .verifying : .preparing) }
                check(text("dictionaries.status", in: window).contains(stage == .verify ? "正在验证" : "正在准备"))
            }
            await until("Injected update failure") { !service.isBusy }
            await verifyFailure(stage, window: window, service: service)
            check(service.active?.activatedAt == date.value && text("dictionaries.activatedAt", in: window) == activationLabel)
        }
        delay.value = false
        fault.value = error(.check)
        await press("dictionaries.check", in: window)
        await until("Check failure") { !service.isBusy }
        await verifyFailure(.check, window: window, service: service)
        preferences.present()
        check(service.failure?.stage == .check, "Bringing visible Settings forward preserves current failure")
        await show(.about, window: window, settings: settings, service: service)
        check(service.failure?.stage == .check, "Pane switch preserves current failure")
        window.close()
        check(service.failure == nil && !service.isPresented, "Real NSWindow close clears error even in About")
        preferences.present()
        await show(.dictionaries, window: window, settings: settings, service: service)
        check(service.failure == nil && element("dictionaries.failure", in: window) == nil && service.canRetry)
        check(element("dictionaries.retry", in: window) != nil, "Dismissed error retains retry capability")
        let beforeLogs = logs.value.count
        delay.value = true
        await press("dictionaries.retry", in: window)
        window.close()
        await until("Failure completed while closed") { !service.isBusy }
        preferences.present()
        check(service.failure == nil && logs.value.count == beforeLogs + 1, "Closed failure logs once and never replays")
        delay.value = false
        fault.value = nil; changed.value = false
        await press("dictionaries.retry", in: window)
        await until("Retry no update") { !service.isBusy }
        check(text("dictionaries.status", in: window).contains("无需更新") && !service.canUpdate)
        check(service.active?.activatedAt == date.value)
        changed.value = true
        await press("dictionaries.check", in: window); await until("Changed again") { !service.isBusy }
        await press("dictionaries.update", in: window); await until("Content unchanged") { !service.isBusy }
        check(service.activity == .upToDate && service.active?.activatedAt == date.value)
        print("PASS dictionary UI operations: explicit check/download, busy single-flight, progress, no-change, same-content/date, all preparation errors, next-operation clear, native close/front/pane/closed-failure lifetime and retained retry/log")

        prepared.value = true
        await press("dictionaries.check", in: window); await until("Prepared check") { !service.isBusy }
        let engine = IFEngine()!
        type(engine, "nihao")
        await press("dictionaries.update", in: window)
        await until("Waiting for synthetic composition") { service.activity == .waitingForIdle }
        check(text("dictionaries.status", in: window).contains("等待所有输入完成"))
        await fit(window, required: ["dictionaries.check"])
        date.value = date.value.addingTimeInterval(600)
        engine.clear()
        await until("Native switch completed") { !service.isBusy }
        check(service.activity == .updated && service.active?.activatedAt == date.value)
        check(text("dictionaries.status", in: window).contains("已更新并启用"))

        for rollbackFails in [false, true] {
            service.activationFault = { step, rollback in
                if step == .probe && (!rollback || rollbackFails) { throw error(.apply) }
            }
            await press("dictionaries.check", in: window); await until("Apply check") { !service.isBusy }
            await press("dictionaries.update", in: window); await until("Apply/rollback failed") { !service.isBusy }
            let stage: IFDictionaryStage = rollbackFails ? .rollback : .apply
            await verifyFailure(stage, window: window, service: service)
            check(service.engineAvailable == !rollbackFails)
            if rollbackFails {
                check(element("dictionaries.version", in: window) == nil && element("dictionaries.unavailable", in: window) != nil)
                window.close(); preferences.present()
                check(service.failure == nil && element("dictionaries.retry", in: window) != nil)
            } else { check(text("dictionaries.version", in: window).contains(manifest.contentVersion)) }
        }
        service.activationFault = { _, _ in }
        await press("dictionaries.retry", in: window)
        await until("Unavailable engine recovered") { !service.isBusy }
        check(service.engineAvailable && service.failure == nil)
        window.close(); IFEngine.stop()

        let unavailable = IFDictionaryCoordinator(backendFactory: { throw error(.recovery) })
        let recoveryWindow = IFSettingsWindowController(settings: settings)
        recoveryWindow.dictionaries = unavailable
        recoveryWindow.present(); unavailable.bootstrap()
        await show(.dictionaries, window: recoveryWindow.window!, settings: settings, service: unavailable)
        await verifyFailure(.recovery, window: recoveryWindow.window!, service: unavailable)
        check(element("dictionaries.version", in: recoveryWindow.window!) == nil)
        recoveryWindow.window!.close()
        print("PASS dictionary UI activation: native waiting/success, real apply rollback and engine-unavailable failure, dismissed-failure recovery retry, Chinese recovery error")
    }

    nonisolated static func error(_ stage: IFDictionaryStage) -> IFDictionaryUpdateError {
        .init(stage, "synthetic-\(stage.rawValue)", source: "frost-base", file: "cn_dicts/base.dict.yaml",
              httpStatus: 429, exitStatus: 17, detail: "NSURLErrorDomain (-1009)",
              stderr: String(repeating: "long-diagnostic-segment", count: 80) + "\n" +
                String(repeating: "synthetic worker diagnostic line 中文 0123456789\n", count: 250) + "TAIL-DIAGNOSTIC")
    }

    static func verifyFailure(_ stage: IFDictionaryStage, window: NSWindow, service: IFDictionaryCoordinator) async {
        drainEvents()
        check(service.failure?.stage == stage, "Expected \(stage), got \(String(describing: service.failure))")
        check(text("dictionaries.failure", in: window).contains(stage.failureSummary))
        check(text("dictionaries.failureStage", in: window).contains(stage.displayName))
        check(element("dictionaries.retry", in: window) != nil)
        await pressDisclosure("错误详情", in: window)
        let detail = text("dictionaries.errorDetails", in: window)
        check(detail.contains(service.failure!.technicalDetails), "Full diagnostic must be accessible/selectable")
        await fit(window, required: ["dictionaries.check", "dictionaries.retry", "dictionaries.failure"], disclosures: ["错误详情"])
        check(element("dictionaries.errorDetails", in: window) != nil)
        await pressDisclosure("错误详情", in: window)
    }

    static func show(_ section: SettingsSection, window: NSWindow, settings: IFSettings, service: IFDictionaryCoordinator?) async {
        window.contentViewController = SettingsHostingController(rootView: SettingsView(settings: settings, dictionaries: service, initialSection: section))
        try? await Task.sleep(for: .milliseconds(200))
        drainEvents()
        SettingsUITests.checkMinimumSize(window)
    }

    static func element(_ identifier: String, in window: NSWindow) -> [String: Any]? {
        window.contentView?.layoutSubtreeIfNeeded()
        let matches = IFAccessibilityTree(window).filter { $0["id"] as? String == identifier }
        if matches.count > 1 { dumpAccessibility(window) }
        check(matches.count <= 1, "Duplicate accessibility identifier \(identifier): \(matches.count) matches")
        return matches.first
    }
    static func disclosure(_ label: String, in window: NSWindow) -> [String: Any]? {
        window.contentView?.layoutSubtreeIfNeeded()
        let matches = IFAccessibilityTree(window).filter {
            $0["role"] as? String == "AXDisclosureTriangle" && $0["label"] as? String == label
        }
        if matches.count != 1 { dumpAccessibility(window) }
        check(matches.count == 1, "Expected one native disclosure \(label), found \(matches.count)")
        return matches.first
    }
    static func dumpAccessibility(_ window: NSWindow) {
        for item in IFAccessibilityTree(window) { print("AX dictionary \(item)") }
    }
    static func text(_ identifier: String, in window: NSWindow) -> String {
        drainEvents(seconds: 0.02)
        guard let element = element(identifier, in: window) else {
            dumpAccessibility(window)
            check(false, "Missing accessible text \(identifier)")
            return ""
        }
        return "\(element["label"] ?? "") \(element["value"] ?? "")"
    }
    static func checkText(_ identifier: String, contains expected: String, in window: NSWindow) {
        let actual = text(identifier, in: window)
        if !actual.contains(expected) { dumpAccessibility(window) }
        check(actual.contains(expected), "\(identifier): expected \(expected), got \(actual)")
    }
    static func press(_ identifier: String, in window: NSWindow) async {
        drainEvents(seconds: 0.02)
        let pressed = element(identifier, in: window) != nil && IFPressAccessibility(window, identifier)
        if !pressed { dumpAccessibility(window) }
        check(pressed, "Native AX press \(identifier)")
        try? await Task.sleep(for: .milliseconds(50))
        drainEvents(seconds: 0.02)
    }
    static func pressDisclosure(_ label: String, in window: NSWindow) async {
        let wasExpanded = (disclosure(label, in: window)?["value"] as? NSNumber)?.boolValue
        check(wasExpanded != nil, "Native disclosure \(label) must expose its expanded state")
        let pressed = IFPressAccessibilityDisclosure(window, label)
        if !pressed { dumpAccessibility(window) }
        check(pressed, "Native AX disclosure press \(label)")
        let deadline = Date().addingTimeInterval(2)
        while (disclosure(label, in: window)?["value"] as? NSNumber)?.boolValue == wasExpanded, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            drainEvents(seconds: 0.02)
        }
        let expanded = (disclosure(label, in: window)?["value"] as? NSNumber)?.boolValue
        if expanded != !wasExpanded! { dumpAccessibility(window) }
        check(expanded == !wasExpanded!, "Native disclosure \(label) must toggle its expanded state")
    }
    static func fit(_ window: NSWindow, required: [String], disclosures: [String] = []) async {
        for size in [NSSize(width: 700, height: 380), NSSize(width: 700, height: 700)] {
            window.setContentSize(size); try? await Task.sleep(for: .milliseconds(50)); drainEvents()
            SettingsUITests.checkMinimumSize(window)
            let frame = window.convertToScreen(window.contentLayoutRect)
            let targets = required.map { ($0, element($0, in: window)) } +
                disclosures.map { ("disclosure \($0)", disclosure($0, in: window)) }
            for (identifier, item) in targets {
                guard let control = (item?["frame"] as? NSValue)?.rectValue else {
                    check(false, "Missing accessible \(identifier)"); return
                }
                if !frame.contains(control) { dumpAccessibility(window) }
                check(control.width > 0 && control.height > 0 && frame.contains(control), "\(identifier) must fit at \(size): \(control), content \(frame)")
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
