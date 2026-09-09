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
    private var font = NSFont.systemFont(ofSize: 14)
    private var maximumWidth: CGFloat = 520
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    static func isSuggestionWindow(_ window: NSWindow) -> Bool { window is AISuggestionWindow }

    init() {
        body = NSTextField(wrappingLabelWithString: "")
        heading = NSTextField(labelWithString: "AI")
        hint = NSTextField(labelWithString: "Tab 采纳")
        body.textColor = .labelColor
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        let size = NSSize(width: 200, height: 28)
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
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.autoresizingMask = [.width, .height]
        background.layer?.masksToBounds = true
        panel.contentView = background

        heading.font = .systemFont(ofSize: 11, weight: .medium)
        heading.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .right
        background.addSubview(heading)
        background.addSubview(hint)
        background.addSubview(body)
    }

    func setSuggestion(_ text: String, font: NSFont = .systemFont(ofSize: 14)) {
        guard text != suggestion || self.font != font else { return }
        suggestion = text
        self.font = font
        body.stringValue = text
        body.font = font
        panel.setAccessibilityValue(text)
        layout()
    }

    private func layout() {
        let inset: CGFloat = 12, gap: CGFloat = 8, maximumHeight: CGFloat = 170
        heading.stringValue = "AI"
        let hintSize = hint.fittingSize
        // Reserve the text field inset in addition to the measured string width.
        let naturalWidth = ceil((suggestion as NSString).size(withAttributes: [.font: font]).width) + 4
        func measure() -> (CGFloat, CGFloat, CGFloat) {
            let headingWidth = ceil(heading.fittingSize.width)
            let chrome = inset * 2 + gap * 2 + headingWidth + ceil(hintSize.width)
            let width = max(chrome + max(font.pointSize, 24), min(maximumWidth, chrome + naturalWidth))
            let bodyWidth = max(1, width - chrome)
            body.preferredMaxLayoutWidth = bodyWidth
            return (width, bodyWidth, ceil(body.fittingSize.height))
        }
        var (width, bodyWidth, naturalHeight) = measure()
        if naturalHeight > maximumHeight {
            heading.stringValue = "AI · 部分显示"
            (width, bodyWidth, naturalHeight) = measure()
        }
        let bodyHeight = min(naturalHeight, maximumHeight)
        let height = max(bodyHeight, max(heading.fittingSize.height, hintSize.height)) + 10
        let headingWidth = ceil(heading.fittingSize.width)
        heading.frame = NSRect(x: inset, y: (height - heading.fittingSize.height) / 2,
                               width: headingWidth, height: heading.fittingSize.height)
        body.frame = NSRect(x: inset + headingWidth + gap, y: (height - bodyHeight) / 2,
                            width: bodyWidth, height: bodyHeight)
        hint.frame = NSRect(x: width - inset - hintSize.width, y: (height - hintSize.height) / 2,
                            width: hintSize.width, height: hintSize.height)
        panel.setContentSize(NSSize(width: width, height: height))
        let singleLineHeight = ceil(font.ascender - font.descender + font.leading) + 4
        panel.contentView?.layer?.cornerRadius = bodyHeight <= singleLineHeight ? height / 2 : 12
        panel.invalidateShadow()
    }

    func show(relativeTo candidateFrame: NSRect,
              screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) {
        if let screen = Self.screen(for: candidateFrame, screens: screens),
           maximumWidth != min(520, screen.width) {
            maximumWidth = min(520, screen.width)
            layout()
        }
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
        guard let screen = Self.screen(for: candidateFrame, screens: screens),
              panelSize.width <= screen.width, panelSize.height <= screen.height else { return nil }

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
    nonisolated private static func screen(for candidateFrame: NSRect, screens: [NSRect]) -> NSRect? {
        func overlap(_ screen: NSRect) -> CGFloat {
            let intersection = screen.intersection(candidateFrame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        func distance(_ screen: NSRect) -> CGFloat {
            let dx = candidateFrame.midX - min(max(candidateFrame.midX, screen.minX), screen.maxX)
            let dy = candidateFrame.midY - min(max(candidateFrame.midY, screen.minY), screen.maxY)
            return dx * dx + dy * dy
        }
        return screens.filter { $0.width > 0 && $0.height > 0 && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite) }.max(by: { lhs, rhs in
            let leftOverlap = overlap(lhs), rightOverlap = overlap(rhs)
            return leftOverlap == rightOverlap ? distance(lhs) > distance(rhs) : leftOverlap < rightOverlap
        })

    }
}
