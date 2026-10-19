import CoreGraphics
import Foundation

/// Petal layout for the radial wheel. Petals start at 12 o'clock and go clockwise.
/// Coordinates are y-up (non-flipped AppKit views).
enum WheelGeometry {
    static let inner: CGFloat = 48.64
    static let outer: CGFloat = 119.52
    static let gap: CGFloat = 4
    static let corner: CGFloat = 20.16
    /// Diameter of the wheel.
    static let diameter: CGFloat = 272

    static func centerAngle(index: Int, count: Int) -> CGFloat {
        let start: CGFloat = count == 3 ? .pi : .pi / 2
        return start - 2 * .pi * CGFloat(index) / CGFloat(max(count, 1))
    }

    /// Rounded annular sector with even gaps between neighbors.
    static func petalPath(index: Int, count: Int, center c: CGPoint) -> CGPath {
        let a = centerAngle(index: index, count: count)
        let span = 2 * .pi / CGFloat(max(count, 1))
        let l = a - span / 2, s = a + span / 2
        // Half-gap angle at radius j, so gaps stay a constant width.
        func halfGap(_ j: CGFloat) -> CGFloat { asin(min(0.95, gap / 2 / max(j, gap / 2 + 0.01))) }
        let d = l + halfGap(outer), i = s - halfGap(outer)
        let cc = l + halfGap(inner), g = s - halfGap(inner)
        let f = min(0.15, (i - d) * 0.24)
        let u = min(0.18, (g - cc) * 0.18)
        let v = inner / max(0.01, cos(u))
        let y = v + inner * tan(u)
        let o = outer - corner
        func p(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
        }

        let path = CGMutablePath()
        path.move(to: p(y, l + halfGap(y)))
        path.addLine(to: p(o, l + halfGap(o)))
        path.addQuadCurve(to: p(outer, d + f), control: p(outer, d))
        path.addArc(center: c, radius: outer, startAngle: d + f, endAngle: i - f, clockwise: false)
        path.addQuadCurve(to: p(o, s - halfGap(o)), control: p(outer, i))
        path.addLine(to: p(y, s - halfGap(y)))
        path.addQuadCurve(to: p(inner, g - u), control: p(v, s - halfGap(v)))
        path.addArc(center: c, radius: inner, startAngle: g - u, endAngle: cc + u, clockwise: true)
        path.addQuadCurve(to: p(y, l + halfGap(y)), control: p(v, l + halfGap(v)))
        path.closeSubpath()
        return path
    }

    /// Where a petal's label is centered.
    static func labelPoint(index: Int, count: Int, center c: CGPoint) -> CGPoint {
        let a = centerAngle(index: index, count: count)
        let radius = (inner + outer) / 2 + 2
        return CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
    }

    /// The petal under `point`, or nil in the center hole. Anything beyond the rim still selects
    /// the nearest petal so quick flicks work.
    static func index(at point: CGPoint, center c: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - c.x, dy = point.y - c.y
        guard hypot(dx, dy) >= inner - 4 else { return nil }
        let start: CGFloat = count == 3 ? .pi : .pi / 2
        let step = 2 * .pi / CGFloat(count)
        let k = Int(((start - atan2(dy, dx)) / step).rounded())
        return ((k % count) + count) % count
    }
}
