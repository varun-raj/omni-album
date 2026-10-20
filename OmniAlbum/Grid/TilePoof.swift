import QuartzCore
import CoreGraphics

/// macOS Dock-style delete: the tile shrinks to 0.6 and fades while a puff of smoke bursts from its centre.
/// Core Animation only (no frame timers). Reduce Motion: a plain 0.15 s fade.
extension ScatterGridView {
    func poof(_ t: CALayer) {
        let p = t.presentation() ?? t, opacity = p.opacity
        let scale = p.value(forKeyPath: "transform.scale") ?? 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        t.removeAllAnimations(); t.position = p.position; t.bounds = p.bounds; t.transform = p.transform // freeze mid-spring
        t.opacity = 0; t.zPosition = -1 // neighbours reflowing over it pass on top
        CATransaction.setCompletionBlock { t.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = opacity; fade.toValue = 0
        if reduceMotion {
            fade.duration = 0.15
            t.add(fade, forKey: "poof")
        } else {
            let shrink = CABasicAnimation(keyPath: "transform.scale"); shrink.fromValue = scale; shrink.toValue = 0.6
            let g = CAAnimationGroup(); g.animations = [fade, shrink]; g.duration = 0.18
            g.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1) // spring-ish ease-out
            g.fillMode = .forwards; g.isRemovedOnCompletion = false
            t.add(g, forKey: "poof")
            puff(at: p.position, in: t.superlayer ?? root)
        }
        CATransaction.commit()
    }

    /// ~24 soft grey particles flying out 360°, growing 0.4→1.4 and fading over ~0.45 s, then the emitter goes.
    func puff(at center: CGPoint, in host: CALayer) {
        let c = CAEmitterCell()
        c.contents = Self.puffImage
        c.birthRate = 300; c.lifetime = 0.45; c.lifetimeRange = 0.08 // 300/s for 0.08 s ≈ 24 particles
        c.velocity = 90; c.velocityRange = 30; c.emissionRange = .pi * 2
        c.scale = 0.4; c.scaleSpeed = 2.2 // ≈ 1.4 by the end of its life
        c.color = CGColor(gray: 0.5, alpha: 0.6); c.alphaSpeed = -1.3 // mid-grey: lighter than a dark canvas, darker than a light one
        c.spinRange = 3
        let e = CAEmitterLayer()
        e.position = center; e.emitterPosition = .zero; e.emitterShape = .point
        e.emitterCells = [c]; e.zPosition = 10; e.beginTime = CACurrentMediaTime()
        e.add(Self.burst, forKey: "burst")
        host.addSublayer(e)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { e.removeFromSuperlayer() } // one-shot cleanup, not a frame timer
    }

    /// The emitter's birthRate drops to 0 after 0.08 s: a burst, not a stream.
    static let burst: CAAnimation = {
        let a = CAKeyframeAnimation(keyPath: "birthRate")
        a.values = [1, 0]; a.keyTimes = [0, NSNumber(value: 0.08 / 0.6), 1]; a.calculationMode = .discrete; a.duration = 0.6
        a.fillMode = .forwards; a.isRemovedOnCompletion = false
        return a
    }()

    /// A 32 px white radial blob (opaque centre → clear edge); the cell's colour tints it grey.
    static let puffImage: CGImage? = {
        let n = 32, cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])
        else { return nil }
        let m = CGPoint(x: n / 2, y: n / 2)
        ctx.drawRadialGradient(g, startCenter: m, startRadius: 0, endCenter: m, endRadius: CGFloat(n) / 2, options: [])
        return ctx.makeImage()
    }()
}
