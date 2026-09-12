import AppKit
import QuartzCore

@MainActor
private final class ThunderWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A reusable, click-through screen overlay. Each input action adds only a
/// handful of Core Animation layers; no window or view is created per keypress.
@MainActor
final class ThunderPanel {
    private let panel: ThunderWindow
    private let canvas: CALayer
    private var dismissTimer: Timer?
    private var particles: [(layer: CALayer, expiresAt: TimeInterval)] = []

    init() {
        panel = ThunderWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.setAccessibilityElement(false)

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        canvas = CALayer()
        canvas.masksToBounds = true
        view.layer = canvas
        view.setAccessibilityElement(false)
        panel.contentView = view
    }

    func burst(_ burst: ThunderBurst, at caretRect: NSRect,
               screens: [NSRect] = NSScreen.screens.map(\.frame)) {
        guard let screen = Self.screen(for: caretRect, screens: screens) else {
            hide()
            return
        }
        if panel.frame != screen {
            removeAllParticles()
            panel.setFrame(screen, display: false)
            canvas.frame = NSRect(origin: .zero, size: screen.size)
        }
        let origin = CGPoint(x: caretRect.midX - screen.minX, y: caretRect.midY - screen.minY)
        addParticles(for: burst, at: origin)
        if !panel.isVisible { panel.orderFrontRegardless() }
        scheduleDismiss(after: burst == .commit ? 0.9 : 0.7)
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        removeAllParticles()
        panel.orderOut(nil)
    }

    private func addParticles(for burst: ThunderBurst, at origin: CGPoint) {
        let now = CACurrentMediaTime()
        particles.removeAll { particle in
            guard particle.expiresAt <= now else { return false }
            particle.layer.removeFromSuperlayer()
            return true
        }
        let count = burst == .commit ? 18 : 8
        let colors: [CGColor] = [
            NSColor.systemPink.cgColor, NSColor.systemOrange.cgColor,
            NSColor.systemYellow.cgColor, NSColor.systemGreen.cgColor,
            NSColor.systemTeal.cgColor, NSColor.systemBlue.cgColor,
            NSColor.systemPurple.cgColor,
        ]
        let duration = burst == .commit ? 0.78 : 0.52
        let reach = burst == .commit ? 82.0 : 46.0

        for index in 0..<count {
            let angle = Double(index) / Double(count) * .pi * 2 + Double.random(in: -0.12...0.12)
            let distance = reach * Double.random(in: 0.72...1.08)
            let end = CGPoint(x: origin.x + cos(angle) * distance,
                              y: origin.y + sin(angle) * distance - (burst == .commit ? 34 : 18))
            let control = CGPoint(x: origin.x + cos(angle) * distance * 0.55,
                                  y: origin.y + sin(angle) * distance * 0.55 + reach * 0.38)
            let particle = CAShapeLayer()
            particle.bounds = CGRect(x: 0, y: 0,
                                     width: burst == .commit ? 4 : 3,
                                     height: burst == .commit ? 9 : 7)
            particle.position = origin
            particle.path = CGPath(rect: particle.bounds, transform: nil)
            particle.fillColor = colors[index % colors.count]
            canvas.addSublayer(particle)

            let position = CAKeyframeAnimation(keyPath: "position")
            let path = CGMutablePath()
            path.move(to: origin)
            path.addQuadCurve(to: end, control: control)
            position.path = path

            let rotation = CABasicAnimation(keyPath: "transform.rotation")
            rotation.fromValue = Double.random(in: 0...(.pi * 2))
            rotation.toValue = Double.random(in: (.pi * 2)...(.pi * 6))

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [1, 1, 0]
            opacity.keyTimes = [0, 0.62, 1]

            let animation = CAAnimationGroup()
            animation.animations = [position, rotation, opacity]
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animation.isRemovedOnCompletion = false
            animation.fillMode = .forwards
            particle.add(animation, forKey: "thunder")
            particles.append((particle, now + duration))
        }
    }

    private func removeAllParticles() {
        particles.forEach { $0.layer.removeFromSuperlayer() }
        particles.removeAll(keepingCapacity: true)
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        dismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    nonisolated static func screen(for caretRect: NSRect, screens: [NSRect]) -> NSRect? {
        guard valid(caretRect), caretRect.height > 0 else { return nil }
        let candidates = screens.filter { valid($0) && $0.width > 0 && $0.height > 0 }
        return candidates.max {
            let left = overlap($0, caretRect), right = overlap($1, caretRect)
            return left == right ? distance($0, caretRect) > distance($1, caretRect) : left < right
        }
    }

    nonisolated private static func valid(_ rect: NSRect) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
    }

    nonisolated private static func overlap(_ screen: NSRect, _ caret: NSRect) -> CGFloat {
        let intersection = screen.intersection(caret)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    nonisolated private static func distance(_ screen: NSRect, _ caret: NSRect) -> CGFloat {
        let dx = caret.midX - min(max(caret.midX, screen.minX), screen.maxX)
        let dy = caret.midY - min(max(caret.midY, screen.minY), screen.maxY)
        return dx * dx + dy * dy
    }
}
