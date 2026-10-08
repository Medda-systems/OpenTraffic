import AppKit
import SwiftUI

// Ambient, endlessly repeating animations run as Core Animation layers. The window server drives
// them, so they cost the app no CPU per frame — unlike SwiftUI timelines and phase animators, which
// re-evaluate and lay out the view hierarchy on every frame.

/// A ring or disc that expands and fades out, over and over.
struct PulseRing: NSViewRepresentable {
    var color: Color
    var filled = false
    var lineWidth: CGFloat = 2
    var scale: CGFloat
    var startOpacity: Float
    var duration: CFTimeInterval

    func makeNSView(context: Context) -> PulseRingView {
        PulseRingView()
    }

    func updateNSView(_ view: PulseRingView, context: Context) {
        view.configure(.init(
            color: NSColor(color),
            filled: filled,
            lineWidth: lineWidth,
            scale: scale,
            startOpacity: startOpacity,
            duration: duration
        ))
    }
}

final class PulseRingView: NSView {
    struct Configuration: Equatable {
        var color: NSColor
        var filled: Bool
        var lineWidth: CGFloat
        var scale: CGFloat
        var startOpacity: Float
        var duration: CFTimeInterval
    }

    private var configuration: Configuration?
    private let ring = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ configuration: Configuration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        apply()
    }

    override func layout() {
        super.layout()
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func apply() {
        guard let configuration, bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        let inset = configuration.filled ? 0 : configuration.lineWidth / 2
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = configuration.color.cgColor
            ring.fillColor = configuration.filled ? color : nil
            ring.strokeColor = configuration.filled ? nil : color
        }
        ring.lineWidth = configuration.lineWidth
        ring.opacity = 0
        CATransaction.commit()

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = configuration.scale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = configuration.startOpacity
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = configuration.duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        ring.removeAnimation(forKey: "pulse")
        ring.add(group, forKey: "pulse")
    }
}

/// Dots travelling left to right along a link, fading in and out at the ends.
struct PacketStream: NSViewRepresentable {
    var count: Int
    /// Seconds for one dot to cross the link.
    var period: CFTimeInterval
    var inset: CGFloat
    var color: Color = .green

    func makeNSView(context: Context) -> PacketStreamView {
        PacketStreamView()
    }

    func updateNSView(_ view: PacketStreamView, context: Context) {
        view.configure(.init(count: count, period: period, inset: inset, color: NSColor(color)))
    }
}

final class PacketStreamView: NSView {
    struct Configuration: Equatable {
        var count: Int
        var period: CFTimeInterval
        var inset: CGFloat
        var color: NSColor
    }

    private var configuration: Configuration?
    private var builtSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ configuration: Configuration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        rebuild()
    }

    override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func rebuild() {
        guard let layer else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        builtSize = bounds.size
        guard let configuration, configuration.count > 0, bounds.width > configuration.inset * 2 + 5 else { return }
        var color = NSColor.systemGreen.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = configuration.color.cgColor }

        let start = configuration.inset
        let end = bounds.width - configuration.inset
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        for index in 0..<configuration.count {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
            dot.cornerRadius = 2.5
            dot.backgroundColor = color
            dot.position = CGPoint(x: start, y: bounds.midY)
            dot.opacity = 0

            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = start
            move.toValue = end
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.17, 0.83, 1]
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = configuration.period
            group.repeatCount = .infinity
            // Spread the dots evenly along the link.
            group.beginTime = now - configuration.period * Double(index) / Double(configuration.count)
            dot.add(group, forKey: "flow")
            layer.addSublayer(dot)
        }
    }
}
