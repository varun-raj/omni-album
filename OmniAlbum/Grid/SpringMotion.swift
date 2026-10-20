import QuartzCore

/// A Core Animation spring. `animation(…)` always plays the full settle, sped up (or slowed) so it lands in
/// `duration` seconds; a duration of 0 plays it at its natural speed.
public struct SpringMotion: Equatable, Sendable {
    /// `CASpringAnimation` parameters: mass, stiffness and damping (unitless).
    public var mass: CGFloat, stiffness: CGFloat, damping: CGFloat
    /// Bounce mode when set: every animation rebuilds the spring with its own duration as the response (see `bounce(_:response:)`),
    /// so open (0.30 s) and scatter (0.35 s) share a shape at their own pace. nil: mass / stiffness / damping as given.
    public var bounce: CGFloat?

    /// A spring with the given mass, stiffness and damping.
    public init(mass: CGFloat, stiffness: CGFloat, damping: CGFloat) {
        self.mass = mass; self.stiffness = stiffness; self.damping = damping
    }

    /// Response `r` seconds, bounce `b` (0 = critically damped, 1 = undamped), via `CASpringAnimation(perceptualDuration:bounce:)`
    /// (SwiftUI `.spring(duration:bounce:)`). 0.30 s / 0.1 gives stiffness 438.6, damping 37.7 (ζ 0.9): 98 % settled at 0.16 s, 0.15 % overshoot.
    public static func bounce(_ b: CGFloat, response r: Double = 0.30) -> SpringMotion {
        let a = native(b, r)
        var s = SpringMotion(mass: a.mass, stiffness: a.stiffness, damping: a.damping)
        s.bounce = min(max(b, 0), 1)
        return s
    }

    private static func native(_ b: CGFloat, _ r: Double) -> CASpringAnimation {
        CASpringAnimation(perceptualDuration: max(r, 0.05), bounce: min(max(b, 0), 1))
    }

    /// Open, close, scatter and re-layout: bounce 0.1.
    public static let item = bounce(0.1)
    /// Hover lift, selection and the title pill.
    public static let hover = SpringMotion(mass: 3, stiffness: 335.7, damping: 28.39)

    /// A spring animation on `keyPath` from `from` to `to`, sped up or slowed to settle in `duration` seconds (0 = natural).
    public func animation(keyPath: String, from: Any?, to: Any, duration: Double = 0) -> CASpringAnimation {
        let a: CASpringAnimation
        if let b = bounce, duration > 0.01 {
            a = Self.native(b, duration); a.keyPath = keyPath
        } else {
            a = CASpringAnimation(keyPath: keyPath)
            a.mass = mass; a.stiffness = stiffness; a.damping = damping
        }
        a.initialVelocity = 0
        a.fromValue = from; a.toValue = to
        a.duration = a.settlingDuration
        a.speed = duration > 0.01 ? Float(a.duration / duration) : 1
        return a
    }
}
