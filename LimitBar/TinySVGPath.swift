// TinySVGPath.swift — minimal SVG path parser → CGPath
// Supports M m L l H h V v C c S s A a Z z. Absolute/relative, multi-subpath.

import CoreGraphics
import Foundation

enum TinySVGPath {
    static func parse(_ d: String, into path: CGMutablePath? = nil) -> CGMutablePath {
        let p = path ?? CGMutablePath()
        var x: CGFloat = 0, y: CGFloat = 0          // current point
        var sx: CGFloat = 0, sy: CGFloat = 0        // subpath start
        var prevC: (CGFloat, CGFloat, CGFloat, CGFloat)? = nil  // last cubic ctrl pts (for S/s)
        var i = d.startIndex
        let end = d.endIndex
        var cmd: Character? = nil

        func num() -> CGFloat? {
            // skip separators
            while i < end, d[i] == " " || d[i] == "," || d[i] == "\n" || d[i] == "\t" { i = d.index(after: i) }
            guard i < end else { return nil }
            let start = i
            if d[i] == "-" || d[i] == "+" { i = d.index(after: i) }
            var dots = 0
            while i < end {
                let ch = d[i]
                if ch.isNumber { i = d.index(after: i) }
                else if ch == "." && dots == 0 { dots = 1; i = d.index(after: i) }  // only ONE dot per number
                else { break }
            }
            guard i > start else { return nil }
            return CGFloat(Double(d[start..<i]) ?? 0)
        }

        func nums(_ n: Int) -> [CGFloat]? {
            var out: [CGFloat] = []
            for _ in 0..<n { guard let v = num() else { return nil }; out.append(v) }
            return out
        }

        while i < end {
            // skip separators
            while i < end, d[i] == " " || d[i] == "," || d[i] == "\n" || d[i] == "\t" { i = d.index(after: i) }
            guard i < end else { break }
            let ch = d[i]
            if ch.isLetter {
                cmd = ch
                i = d.index(after: i)
            }
            guard let c = cmd else { break }
            let rel = c.isLowercase
            let C = Character(c.uppercased())
            switch C {
            case "M":
                if let v = nums(2) {
                    let nx = rel ? x + v[0] : v[0], ny = rel ? y + v[1] : v[1]
                    if C == "M" && p.isEmpty { p.move(to: CGPoint(x: nx, y: ny)) }
                    else { p.move(to: CGPoint(x: nx, y: ny)) }
                    x = nx; y = ny; sx = nx; sy = ny
                    cmd = rel ? "l" : "L"   // implicit lineto after M
                    prevC = nil
                }
            case "L":
                if let v = nums(2) {
                    let nx = rel ? x + v[0] : v[0], ny = rel ? y + v[1] : v[1]
                    p.addLine(to: CGPoint(x: nx, y: ny))
                    x = nx; y = ny; prevC = nil
                }
            case "H":
                if let v = nums(1) {
                    let nx = rel ? x + v[0] : v[0]
                    p.addLine(to: CGPoint(x: nx, y: y))
                    x = nx; prevC = nil
                }
            case "V":
                if let v = nums(1) {
                    let ny = rel ? y + v[0] : v[0]
                    p.addLine(to: CGPoint(x: x, y: ny))
                    y = ny; prevC = nil
                }
            case "C":
                if let v = nums(6) {
                    let c1 = CGPoint(x: rel ? x + v[0] : v[0], y: rel ? y + v[1] : v[1])
                    let c2 = CGPoint(x: rel ? x + v[2] : v[2], y: rel ? y + v[3] : v[3])
                    let to = CGPoint(x: rel ? x + v[4] : v[4], y: rel ? y + v[5] : v[5])
                    p.addCurve(to: to, control1: c1, control2: c2)
                    prevC = (c1.x, c1.y, c2.x, c2.y)
                    x = to.x; y = to.y
                }
            case "S":
                if let v = nums(4) {
                    let c2 = CGPoint(x: rel ? x + v[0] : v[0], y: rel ? y + v[1] : v[1])
                    let to = CGPoint(x: rel ? x + v[2] : v[2], y: rel ? y + v[3] : v[3])
                    let c1: CGPoint
                    if let pc = prevC { c1 = CGPoint(x: 2 * x - pc.2, y: 2 * y - pc.3) }
                    else { c1 = CGPoint(x: x, y: y) }
                    p.addCurve(to: to, control1: c1, control2: c2)
                    prevC = (c1.x, c1.y, c2.x, c2.y)
                    x = to.x; y = to.y
                }
            case "A":
                if let v = nums(7) {
                    let to = CGPoint(x: rel ? x + v[5] : v[5], y: rel ? y + v[6] : v[6])
                    p.addArcAsSvg(rx: v[0], ry: v[1], rot: v[2], large: v[3] != 0, sweep: v[4] != 0, to: to, cur: CGPoint(x: x, y: y))
                    x = to.x; y = to.y; prevC = nil
                }
            case "Z":
                p.closeSubpath()
                x = sx; y = sy; prevC = nil
            default:
                i = d.index(after: i)
            }
        }
        return p
    }
}

extension CGMutablePath {
    /// SVG elliptical arc → bezier approximation (endpoint parameterization).
    func addArcAsSvg(rx: CGFloat, ry: CGFloat, rot: CGFloat, large: Bool, sweep: Bool, to: CGPoint, cur: CGPoint) {
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 {
            addLine(to: to)
            return
        }
        let phi = rot * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (cur.x - to.x) / 2, dy = (cur.y - to.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        // scale radii
        let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lam > 1 {
            let s = sqrt(lam)
            rx *= s; ry *= s
        }
        let rx2 = rx * rx, ry2 = ry * ry
        let num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
        let den = rx2 * y1p * y1p + ry2 * x1p * x1p
        var co = sqrt(max(0, num / den))
        if large == sweep { co = -co }
        let cxp = co * rx * y1p / ry
        let cyp = -co * ry * x1p / rx
        let cx = cosP * cxp - sinP * cyp + (cur.x + to.x) / 2
        let cy = sinP * cxp + cosP * cyp + (cur.y + to.y) / 2
        // angles
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let th1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dth = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dth > 0 { dth -= 2 * .pi }
        if sweep && dth < 0 { dth += 2 * .pi }
        // split into ≤90° segments
        let segs = max(1, Int(ceil(abs(dth) / (.pi / 2))))
        let delta = dth / CGFloat(segs)
        let t = 4 / 3 * tan(delta / 4)
        var th = th1
        var px = cur.x, py = cur.y
        for _ in 0..<segs {
            let th2 = th + delta
            let cos1 = cos(th), sin1 = sin(th)
            let cos2 = cos(th2), sin2 = sin(th2)
            // point on ellipse
            func ept(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * cosP * c - ry * sinP * s,
                        y: cy + rx * sinP * c + ry * cosP * s)
            }
            let p2 = ept(cos2, sin2)
            let d1 = CGPoint(x: -rx * cosP * sin1 - ry * sinP * cos1, y: -rx * sinP * sin1 + ry * cosP * cos1)
            let d2 = CGPoint(x: -rx * cosP * sin2 - ry * sinP * cos2, y: -rx * sinP * sin2 + ry * cosP * cos2)
            let c1 = CGPoint(x: px + t * d1.x, y: py + t * d1.y)
            let c2 = CGPoint(x: p2.x - t * d2.x, y: p2.y - t * d2.y)
            addCurve(to: p2, control1: c1, control2: c2)
            px = p2.x; py = p2.y
            th = th2
        }
    }
}
