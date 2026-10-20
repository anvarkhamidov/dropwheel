import SwiftUI

/// Геометрия колеса в координатах SwiftUI (y вниз), центр в (0, 0).
/// Сегмент 0 смотрит вверх, дальше по часовой стрелке.
struct WheelGeometry {
    let count: Int
    var inner: CGFloat = Tokens.Wheel.segmentInner
    var outer: CGFloat
    var gap: CGFloat = Tokens.Wheel.gap
    var corner: CGFloat = Tokens.Radius.segment

    /// Тесные колёса (8–10 кнопок) чуть крупнее, чтобы подписи помещались.
    init(count: Int) {
        self.count = count
        self.outer = Tokens.Wheel.segmentOuter + CGFloat(max(0, count - 7)) * Tokens.Wheel.growPerSegment
    }

    /// Радиус подложки с размытием — чуть шире кнопок.
    var backdropRadius: CGFloat { outer + Tokens.Wheel.backdropPadding }

    var step: Double { count > 0 ? 2 * .pi / Double(count) : 0 }

    /// Угол центра сегмента (радианы, 0 = вправо, отсчёт по часовой при y вниз).
    func centerAngle(_ i: Int) -> Double { -.pi / 2 + Double(i) * step }

    func point(_ r: CGFloat, _ a: Double) -> CGPoint { CGPoint(x: r * cos(a), y: r * sin(a)) }

    /// Радиус подписи: чуть ближе к ободу, где лепесток шире.
    var labelRadius: CGFloat { count == 1 ? (inner + outer) / 2 : inner + (outer - inner) * 0.56 }

    /// Центр подписи сегмента.
    func labelCenter(_ i: Int) -> CGPoint { point(labelRadius, centerAngle(i)) }

    /// Доступная горизонтальная ширина подписи в лепестке `i`.
    /// Текст горизонтален, а лепесток повёрнут на угол a: поперёк оси у лепестка есть хорда,
    /// вдоль оси — глубина. Горизонтальный отрезок длины W помещается, если
    /// W·|sin a| ≤ хорда и W·|cos a| ≤ глубина. У верхнего лепестка ограничивает хорда,
    /// у бокового — глубина (раньше бралась хорда, и подписи вылезали вбок).
    func labelWidth(_ i: Int) -> CGFloat {
        guard count > 1 else { return 2 * inner }
        let a = centerAngle(i)
        let chord = 2 * labelRadius * CGFloat(sin(step / 2)) - gap
        let depth = (outer - inner) - corner * 0.8
        let s = CGFloat(abs(sin(a))), c = CGFloat(abs(cos(a)))
        let byChord = s > 0.01 ? chord / s : .greatestFiniteMagnitude
        let byDepth = c > 0.01 ? depth / c : .greatestFiniteMagnitude
        return min(80, min(byChord, byDepth) * 0.86)
    }

    /// Индекс сегмента под точкой или nil (зона ступицы и далеко за ободом не выбирают).
    func index(at p: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let r = hypot(p.x, p.y)
        guard r >= inner * 0.95, r <= Tokens.Wheel.outerRadius * 1.25 else { return nil }
        var a = atan2(Double(p.y), Double(p.x)) + .pi / 2 // 0 = вверх
        if a < 0 { a += 2 * .pi }
        return Int((a / step).rounded()) % count
    }

    /// Лепесток: кольцевой сектор с зазором постоянной ширины и скруглёнными углами.
    func petal(_ i: Int) -> Path {
        var path = Path()
        guard count > 0 else { return path }
        if count == 1 {
            path.addEllipse(in: CGRect(x: -outer, y: -outer, width: 2 * outer, height: 2 * outer))
            path.addEllipse(in: CGRect(x: -inner, y: -inner, width: 2 * inner, height: 2 * inner))
            return path
        }
        let a = centerAngle(i), half = step / 2
        let go = Double(gap / 2 / outer), gi = Double(gap / 2 / inner)
        let a1o = a - half + go, a2o = a + half - go
        let a1i = a - half + gi, a2i = a + half - gi
        // Скругление не больше трети ширины сектора, на внутренней дуге — меньше.
        let maxCo = CGFloat((a2o - a1o) / 3) * outer
        let co = min(corner, maxCo, (outer - inner) / 3)
        let ci = min(corner * 0.6, CGFloat((a2i - a1i) / 3) * inner, (outer - inner) / 3)

        let O1 = point(outer, a1o), O2 = point(outer, a2o)
        let I1 = point(inner, a1i), I2 = point(inner, a2i)
        func toward(_ p: CGPoint, _ q: CGPoint, _ d: CGFloat) -> CGPoint {
            let len = max(hypot(q.x - p.x, q.y - p.y), 0.001)
            return CGPoint(x: p.x + (q.x - p.x) * d / len, y: p.y + (q.y - p.y) * d / len)
        }

        path.move(to: point(outer, a1o + Double(co / outer)))
        path.addArc(center: .zero, radius: outer, startAngle: .radians(a1o + Double(co / outer)),
                    endAngle: .radians(a2o - Double(co / outer)), clockwise: false)
        path.addQuadCurve(to: toward(O2, I2, co), control: O2)
        path.addLine(to: toward(I2, O2, ci))
        path.addQuadCurve(to: point(inner, a2i - Double(ci / inner)), control: I2)
        path.addArc(center: .zero, radius: inner, startAngle: .radians(a2i - Double(ci / inner)),
                    endAngle: .radians(a1i + Double(ci / inner)), clockwise: true)
        path.addQuadCurve(to: toward(I1, O1, ci), control: I1)
        path.addLine(to: toward(O1, I1, co))
        path.addQuadCurve(to: point(outer, a1o + Double(co / outer)), control: O1)
        path.closeSubpath()
        return path
    }
}
