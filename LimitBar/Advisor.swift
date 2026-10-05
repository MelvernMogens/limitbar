import AppKit

// Formatting + severity helpers.

func fmtLeft(_ s: TimeInterval?) -> String {
    guard let s else { return "–" }
    let v = Int(max(0, s))
    let d = v / 86400, h = (v % 86400) / 3600, m = (v % 3600) / 60
    if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
    if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
    return "\(m)m"
}

func fmtAgo(_ s: TimeInterval) -> String {
    let v = Int(max(0, s))
    if v < 60 { return "just now" }
    if v < 3600 { return "\(v / 60)m ago" }
    if v < 86400 { return "\(v / 3600)h ago" }
    return "\(v / 86400)d ago"
}

private let clockFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()
func clock(_ d: Date) -> String { clockFmt.string(from: d) }

func severityColor(_ used: Double) -> NSColor? {
    if used >= 0.9 { return NSColor.systemRed }
    if used >= 0.75 { return NSColor.systemOrange }
    return nil
}

enum AlertLevel: Int, Comparable {
    case none = 0, high, out
    static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rawValue < b.rawValue }
    init(_ used: Double) { self = used >= 0.995 ? .out : (used >= 0.9 ? .high : .none) }
}
