import AppKit

@MainActor
private final class AISuggestionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A passive companion to the native candidate window. The input controller owns
/// presentation and acceptance; this window never receives keyboard or mouse input.
@MainActor
final class AISuggestionPanel {
    private let panel: AISuggestionWindow
    private let body: NSTextField
    private let heading: NSTextField
    private let hint: NSTextField
    private var suggestion = ""
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    static func isSuggestionWindow(_ window: NSWindow) -> Bool { window is AISuggestionWindow }

    init() {
        let width: CGFloat = 310
        body = NSTextField(wrappingLabelWithString: "")
        heading = NSTextField(labelWithString: "AI 建议")
        hint = NSTextField(labelWithString: "Tab 采纳")
        body.font = .systemFont(ofSize: 14)
        body.textColor = .labelColor
        body.preferredMaxLayoutWidth = width - 24
        let bodyHeight = ceil(body.fittingSize.height)
        let size = NSSize(width: width, height: bodyHeight + 42)
        panel = AISuggestionWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.title = "AI 建议 · Tab 采纳"
        panel.setAccessibilityLabel("AI 建议 · Tab 采纳")
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        panel.contentView = background

        let title = heading
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 12, y: size.height - 24, width: 120, height: 14)
        background.addSubview(title)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .right
        hint.frame = NSRect(x: width - 102, y: size.height - 24, width: 90, height: 14)
        background.addSubview(hint)
        body.frame = NSRect(x: 12, y: 10, width: width - 24, height: bodyHeight)
        background.addSubview(body)
    }

    func setSuggestion(_ text: String) {
        guard text != suggestion else { return }
        suggestion = text
        body.stringValue = text
        let width: CGFloat = 310, maximumHeight: CGFloat = 170
        // Explicitly disclose clipping; Tab always inserts the full, complete model response.
        let naturalHeight = ceil(body.fittingSize.height)
        let clipped = naturalHeight > maximumHeight
        let height = min(naturalHeight, maximumHeight)
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        heading.stringValue = clipped ? "AI 建议（部分显示）" : "AI 建议"
        heading.frame = NSRect(x: 12, y: height + 18, width: 180, height: 14)
        hint.frame = NSRect(x: width - 102, y: height + 18, width: 90, height: 14)
        body.frame = NSRect(x: 12, y: 10, width: width - 24, height: height)
        panel.setContentSize(NSSize(width: width, height: height + 42))
        panel.setAccessibilityValue(text)
    }

    func show(relativeTo candidateFrame: NSRect,
              screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) {
        guard let position = Self.position(candidateFrame: candidateFrame, panelSize: panel.frame.size, screens: screens) else {
            hide()
            return
        }
        if panel.frame != position { panel.setFrame(position, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel.orderOut(nil) }

    /// Screen coordinates use a bottom-left origin. Return nil rather than cover
    /// candidates when no available screen region can contain the complete panel.
    nonisolated static func position(candidateFrame: NSRect, panelSize: NSSize,
                                    screens: [NSRect], gap: CGFloat = 6) -> NSRect? {
        func valid(_ rect: NSRect) -> Bool {
            [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) &&
                rect.width > 0 && rect.height > 0
        }
        guard valid(candidateFrame), panelSize.width.isFinite, panelSize.height.isFinite,
              panelSize.width > 0, panelSize.height > 0, gap.isFinite, gap >= 0 else { return nil }
        func overlap(_ screen: NSRect) -> CGFloat {
            let intersection = screen.intersection(candidateFrame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        func distance(_ screen: NSRect) -> CGFloat {
            let dx = candidateFrame.midX - min(max(candidateFrame.midX, screen.minX), screen.maxX)
            let dy = candidateFrame.midY - min(max(candidateFrame.midY, screen.minY), screen.maxY)
            return dx * dx + dy * dy
        }
        guard let screen = screens.filter(valid).max(by: { lhs, rhs in
            let leftOverlap = overlap(lhs), rightOverlap = overlap(rhs)
            return leftOverlap == rightOverlap ? distance(lhs) > distance(rhs) : leftOverlap < rightOverlap
        }), panelSize.width <= screen.width, panelSize.height <= screen.height else { return nil }

        let x = min(max(candidateFrame.minX, screen.minX), screen.maxX - panelSize.width)
        let below = NSRect(x: x, y: candidateFrame.minY - gap - panelSize.height,
                           width: panelSize.width, height: panelSize.height)
        if screen.contains(below) { return below }
        let above = NSRect(x: x, y: candidateFrame.maxY + gap,
                           width: panelSize.width, height: panelSize.height)
        if screen.contains(above) { return above }

        let y = min(max(candidateFrame.minY, screen.minY), screen.maxY - panelSize.height)
        for sideX in [candidateFrame.maxX + gap, candidateFrame.minX - gap - panelSize.width] {
            let side = NSRect(x: sideX, y: y, width: panelSize.width, height: panelSize.height)
            if screen.contains(side) { return side }
        }
        return nil
    }
}
