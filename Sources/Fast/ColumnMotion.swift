import AppKit
import QuartzCore

/// The column's motions (Motion) as Core Animation has them, for the AppKit
/// column (ColumnPages): the same curves and springs, played by the render
/// server rather than a SwiftUI pass a frame.
@MainActor
enum ColumnMotion {
    enum Curve {
        /// A SwiftUI spring: its response and damping fraction.
        case spring(response: Double, damping: Double)
        /// A cubic timing curve and its duration.
        case timing(Float, Float, Float, Float, duration: CFTimeInterval)
    }

    /// Motion.settle: a held row let go, the rows stepping aside.
    static let settle = Curve.spring(response: 0.24, damping: 0.86)
    /// Motion.keptShift.
    static let keptShift = Curve.spring(response: 0.12, damping: 0.9)
    /// Motion.room: a tab opened, the others making room.
    static let room = Curve.timing(0.2, 0.8, 0.2, 1, duration: 0.15)
    /// Motion.leave: a tab closed, the others closing up.
    static let leave = Curve.timing(0.2, 0.8, 0.2, 1, duration: 0.11)
    /// Motion.quick.
    static let quick = Curve.timing(0, 0, 0.58, 1, duration: 0.14)
    /// Folders.clock: a folder opening, and shutting.
    static let opening = Curve.timing(0.2, 0.8, 0.2, 1, duration: 0.16)
    static let shutting = Curve.timing(0, 0, 0.58, 1, duration: 0.10)

    /// Dia's tab group made by a ⌘-click, and a link joining it: the page's
    /// row drops under the folder's, the link's comes in (filmed frame by
    /// frame, docs/evidence/folder-motion-2026-10-16, section 1).
    static let linkFolder = Curve.spring(response: 0.14, damping: 0.85)
    /// A tab closed inside such a folder, the rows below closing up (ibid.,
    /// section 2): Dia's ⌘S spring.
    static let folderClose = Curve.spring(response: 0.16, damping: 0.80)

    /// What the next laying of the column moves on, said by what changed the
    /// row before the column sees it: a curve; `folder`, a folder a ⌘-click
    /// made or filled (on `linkFolder`, its new rows fading in); or `still`
    /// for a change Dia makes in one frame (a folder of today's down to one
    /// tab, ungrouped).
    enum Hint { case curve(Curve), folder, still }
    private static var hint: (Hint, CFTimeInterval)?

    static func next(_ said: Hint) { hint = (said, CACurrentMediaTime()) }

    /// The hint, if said in the last half second: every page laid in the
    /// same turn reads it.
    static var hinted: Hint? {
        guard let (said, at) = hint, CACurrentMediaTime() - at < 0.5 else { return nil }
        return said
    }

    /// An animation of `keyPath` on `curve`, from `from` to `to`.
    static func animation(_ keyPath: String, _ curve: Curve, from: Any?, to: Any?, additive: Bool = false) -> CABasicAnimation {
        let animation: CABasicAnimation
        switch curve {
        case .spring(let response, let damping):
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = 1
            spring.stiffness = pow(2 * .pi / response, 2)
            spring.damping = 4 * .pi * damping / response
            spring.duration = spring.settlingDuration
            animation = spring
        case .timing(let a, let b, let c, let d, let duration):
            animation = CABasicAnimation(keyPath: keyPath)
            animation.timingFunction = CAMediaTimingFunction(controlPoints: a, b, c, d)
            animation.duration = duration
        }
        animation.fromValue = from
        animation.toValue = to
        animation.isAdditive = additive
        animation.fillMode = .backwards
        return animation
    }

    /// How long `curve` takes to land.
    static func duration(_ curve: Curve) -> CFTimeInterval {
        animation("opacity", curve, from: 0, to: 1).duration
    }

    /// `layer` moved by `dy` already (its model where it ends): drawn from
    /// where it was, on `curve`, added to whatever it is still doing.
    static func slide(_ layer: CALayer, by dy: CGFloat, dx: CGFloat = 0, _ curve: Curve, delay: CFTimeInterval = 0) {
        guard abs(dy) > 0.25 || abs(dx) > 0.25 else { return }
        let move = animation("position", curve, from: NSValue(point: CGPoint(x: -dx, y: -dy)), to: NSValue(point: .zero), additive: true)
        if delay > 0 { move.beginTime = CACurrentMediaTime() + delay }
        layer.add(move, forKey: "column.slide.\(UUID().uuidString)")
    }
}
