import AppKit

enum InputStatusLayout {
    static let fontSize: CGFloat = 10
    static let padding: CGFloat = 4

    static func panelSize(for fittingSize: NSSize) -> NSSize {
        let inset = padding * 2
        return NSSize(width: ceil(fittingSize.width + inset), height: ceil(fittingSize.height + inset))
    }

    static func contentFrame(in panelSize: NSSize) -> NSRect {
        let inset = padding * 2
        return NSRect(x: padding, y: padding,
                      width: max(0, panelSize.width - inset), height: max(0, panelSize.height - inset))
    }
}

@MainActor
private final class InputStatusWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Short-lived, focus-free feedback for input state changes.
@MainActor
final class InputStatusPanel {
    private let panel: InputStatusWindow
    private let label: NSTextField
    private var dismissTimer: Timer?

    init() {
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: InputStatusLayout.fontSize, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center

        let size = InputStatusLayout.panelSize(for: label.fittingSize)
        panel = InputStatusWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.title = "输入状态"
        panel.setAccessibilityLabel("输入状态")

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.autoresizingMask = [.width, .height]
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.addSubview(label)
        panel.contentView = background
    }

    func show(_ status: InputStatus, above caretRect: NSRect,
              screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) {
        label.stringValue = status.title
        panel.setAccessibilityValue(status.title)
        let size = InputStatusLayout.panelSize(for: label.fittingSize)
        panel.setContentSize(size)
        label.frame = InputStatusLayout.contentFrame(in: size)
        guard let frame = Self.position(caretRect: caretRect, panelSize: size, screens: screens) else {
            hide()
            return
        }
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard !status.persistent else { return }
        let timer = Timer(timeInterval: 0.9, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        dismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel.orderOut(nil)
    }

    /// Screen coordinates use a bottom-left origin. Prefer the requested
    /// above-caret placement, then use the same horizontal anchor below it.
    nonisolated static func position(caretRect: NSRect, panelSize: NSSize,
                                     screens: [NSRect], gap: CGFloat = 8) -> NSRect? {
        func valid(_ rect: NSRect) -> Bool {
            [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) &&
                rect.width >= 0 && rect.height > 0
        }
        guard valid(caretRect), panelSize.width.isFinite, panelSize.height.isFinite,
              panelSize.width > 0, panelSize.height > 0, gap.isFinite, gap >= 0 else { return nil }
        guard let screen = screen(for: caretRect, screens: screens),
              panelSize.width <= screen.width, panelSize.height <= screen.height else { return nil }

        let x = min(max(caretRect.midX - panelSize.width / 2, screen.minX), screen.maxX - panelSize.width)
        let above = NSRect(x: x, y: caretRect.maxY + gap, width: panelSize.width, height: panelSize.height)
        if screen.contains(above) { return above }
        let below = NSRect(x: x, y: caretRect.minY - gap - panelSize.height,
                           width: panelSize.width, height: panelSize.height)
        return screen.contains(below) ? below : nil
    }

    nonisolated private static func screen(for caretRect: NSRect, screens: [NSRect]) -> NSRect? {
        func overlap(_ screen: NSRect) -> CGFloat {
            let intersection = screen.intersection(caretRect)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        func distance(_ screen: NSRect) -> CGFloat {
            let dx = caretRect.midX - min(max(caretRect.midX, screen.minX), screen.maxX)
            let dy = caretRect.midY - min(max(caretRect.midY, screen.minY), screen.maxY)
            return dx * dx + dy * dy
        }
        return screens.filter {
            $0.width > 0 && $0.height > 0 && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite)
        }.max {
            let leftOverlap = overlap($0), rightOverlap = overlap($1)
            return leftOverlap == rightOverlap ? distance($0) > distance($1) : leftOverlap < rightOverlap
        }
    }
}
