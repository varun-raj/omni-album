#if os(macOS)
import AppKit

/// A drop-effect phase, for hosts that drive the effect without a real drag (demo capture): `.enter` → `.land`.
public enum DropEffectPhase: Sendable { case enter, exit, land }

extension ScatterGridView {
    /// Plays the drop-acceptance effect as a real drag would: starfield on `.enter`, gone on `.exit`, ripple on `.land`.
    public func dropEffect(_ phase: DropEffectPhase) {
        switch phase {
        case .enter: cosmos.begin(in: self)
        case .exit: cosmos.end()
        case .land: cosmos.land()
        }
    }
}

/// "Through the cosmos": while a drag hovers, soft dots stream out from the viewport centre like a head-on starfield
/// over a faint radial vignette; on drop a burst and a 1 px ring ripple out. Core Animation only.
/// Reduce Motion: the vignette alone.
@MainActor final class DropCosmos {
    let emitter = CAEmitterLayer(), vignette = CAGradientLayer()
    weak var grid: ScatterGridView?
    var active = false

    func begin(in g: ScatterGridView) {
        guard !active else { return }
        active = true; grid = g
        let r = g.visibleRect, dark = g.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin(); CATransaction.setDisableActions(true)
        vignette.type = .radial; vignette.frame = r; vignette.zPosition = 20
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5); vignette.endPoint = CGPoint(x: 1, y: 1)
        vignette.colors = [CGColor(gray: dark ? 0 : 1, alpha: 0), CGColor(gray: dark ? 0 : 1, alpha: dark ? 0.10 : 0.06)]
        g.root.addSublayer(vignette)
        animate(vignette, "opacity", to: 1, 0.3)
        if !g.reduceMotion {
            let c = CAEmitterCell()
            c.contents = ScatterGridView.puffImage // 32 px soft blob; × 0.08 ≈ a 2.5 px dot
            c.birthRate = 34; c.lifetime = 1.2; c.lifetimeRange = 0.2 // ≈ 40 alive
            c.velocity = 225; c.velocityRange = 75; c.emissionRange = .pi * 2 // 150–300 pt/s, all directions
            c.scale = 0.3 * 0.08; c.scaleSpeed = (1.6 - 0.3) * 0.08 / 1.2 // 0.3 → 1.6 of a dot over its life
            c.color = color(g, 0.5); c.alphaSpeed = -0.35
            emitter.emitterCells = [c]
            emitter.frame = r; emitter.zPosition = 21; emitter.opacity = 1; emitter.removeAnimation(forKey: "opacity") // land() fades it
            emitter.emitterPosition = CGPoint(x: r.width / 2, y: r.height / 2)
            emitter.emitterShape = .circle; emitter.emitterMode = .volume // born across a small disc, not one point
            emitter.emitterSize = CGSize(width: min(r.width, r.height) * 0.15, height: min(r.width, r.height) * 0.15)
            emitter.beginTime = CACurrentMediaTime()
            g.root.addSublayer(emitter)
            animate(emitter, "birthRate", to: 1, 0.3)
        }
        CATransaction.commit()
    }

    /// Spike ×4 for 0.15 s, ring from 0.2× to the viewport diagonal over 0.5 s, then wind down. Never blocks input.
    func land() {
        guard let g = grid, active else { return }
        end(after: 0.15) // first, so the spike below sits on top of its wind-down
        if !g.reduceMotion {
            let r = g.visibleRect, d = hypot(r.width, r.height), m = CGPoint(x: r.midX, y: r.midY)
            let spike = CAKeyframeAnimation(keyPath: "birthRate")
            spike.values = [4, 4]; spike.duration = 0.15
            emitter.add(spike, forKey: "spike")
            animate(emitter, "opacity", to: 0, 0.6) // whole effect done ≤ 0.6 s after the drop
            let ring = CAShapeLayer(), circle = { (s: CGFloat) in CGPath(ellipseIn: CGRect(x: m.x - d * s / 2, y: m.y - d * s / 2, width: d * s, height: d * s), transform: nil) }
            ring.path = circle(1); ring.fillColor = nil; ring.lineWidth = 1; ring.opacity = 0; ring.zPosition = 22
            ring.strokeColor = color(g, 0.35)
            let grow = CABasicAnimation(keyPath: "path"); grow.fromValue = circle(0.2)
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
            let a = CAAnimationGroup(); a.animations = [grow, fade]; a.duration = 0.5; a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(a, forKey: "ripple"); g.root.addSublayer(ring)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { ring.removeFromSuperlayer() }
        }
    }

    /// birthRate and vignette down over 0.3 s; layers go once the last particles have died.
    func end(after delay: Double = 0) {
        guard active else { return }
        active = false
        let t = CACurrentMediaTime() + delay
        animate(vignette, "opacity", to: 0, 0.3, at: t)
        animate(emitter, "birthRate", to: 0, 0.3, at: t)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.6) { [self] in
            guard !active else { return } // re-entered meanwhile: keep the layers
            vignette.removeFromSuperlayer(); emitter.removeFromSuperlayer()
        }
    }

    func animate(_ l: CALayer, _ key: String, to v: Float, _ duration: Double, at t: CFTimeInterval = 0) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = l.presentation()?.value(forKeyPath: key) ?? (v == 0 ? 1 : 0)
        a.toValue = v; a.duration = duration; a.fillMode = .backwards
        if t > 0 { a.beginTime = t }
        l.setValue(v, forKeyPath: key); l.add(a, forKey: key)
    }

    /// The label colour (white on dark, black on light) at `alpha`.
    func color(_ g: NSView, _ alpha: CGFloat) -> CGColor {
        var c = CGColor(gray: 0, alpha: alpha)
        g.effectiveAppearance.performAsCurrentDrawingAppearance { c = NSColor.labelColor.withAlphaComponent(alpha).cgColor }
        return c
    }
}
#endif
