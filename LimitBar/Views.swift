import AppKit

// MARK: - drawing helpers

let dimText = NSColor(white: 0.62, alpha: 1)
let faintText = NSColor(white: 0.45, alpha: 1)
let trackColor = NSColor(white: 0.26, alpha: 1)
let chipBG = NSColor(white: 0.115, alpha: 1)
let workingGreen = NSColor(srgbRed: 0.30, green: 0.85, blue: 0.45, alpha: 1)
let doneBlue = NSColor(srgbRed: 0.35, green: 0.65, blue: 1.0, alpha: 1)

func attr(_ s: String, _ size: CGFloat, _ w: NSFont.Weight = .regular, _ c: NSColor = .white, mono: Bool = false) -> NSAttributedString {
    let f = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: w) : NSFont.systemFont(ofSize: size, weight: w)
    return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
}

func joined(_ parts: [NSAttributedString]) -> NSAttributedString {
    let m = NSMutableAttributedString()
    parts.forEach { m.append($0) }
    return m
}

/// Shorten to fit `maxW` points, ending with "…".
func fit(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ c: NSColor, maxW: CGFloat) -> NSAttributedString {
    var a = attr(s, size, w, c)
    if a.size().width <= maxW { return a }
    var chars = Array(s)
    while chars.count > 1 {
        chars.removeLast()
        a = attr(String(chars).trimmingCharacters(in: .whitespaces) + "…", size, w, c)
        if a.size().width <= maxW { return a }
    }
    return a
}

func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

func fmtElapsed(_ since: Date) -> String {
    let v = Int(max(0, Date().timeIntervalSince(since)))
    if v < 60 { return "\(v)s" }
    if v < 3600 { return "\(v / 60)m" }
    return "\(v / 3600)h\(String(format: "%02d", (v % 3600) / 60))m"
}

enum Logo {
    private static var cache: [ProviderID: CGPath] = [:]
    static func draw(_ id: ProviderID, center: CGPoint, size: CGFloat, color: NSColor) {
        let path = cache[id] ?? {
            let p = TinySVGPath.parse(id.logoPath)
            cache[id] = p
            return p
        }()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = path.boundingBox
        let s = min(size / max(box.width, 1), size / max(box.height, 1))
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -box.midX, y: -box.midY)
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

func drawBar(_ rect: NSRect, used: Double, color: NSColor, tick: Double? = nil) {
    let r = rect.height / 2
    trackColor.setFill()
    NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
    if used > 0.004 {
        var f = rect
        f.size.width = max(rect.height, rect.width * CGFloat(min(1, used)))
        color.setFill()
        NSBezierPath(roundedRect: f, xRadius: r, yRadius: r).fill()
    }
    // pace tick: how much of the window has elapsed. Fill past the tick = burning faster than even.
    if let t = tick, t > 0.01, t < 0.99 {
        let x = rect.minX + rect.width * CGFloat(t)
        NSColor(white: 1, alpha: 0.85).setFill()
        NSRect(x: x - 0.5, y: rect.minY - 2, width: 1, height: rect.height + 4).fill()
    }
}

// MARK: - base chip (NSButton: the only reliable touch target on the real Touch Bar)

class Chip: NSButton {
    var onTap: (() -> Void)?
    var border: NSColor?
    private(set) var chipWidth: CGFloat = 40

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        isBordered = false
        title = ""
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onTap?() }
    override var isFlipped: Bool { false }

    func setWidth(_ w: CGFloat) {
        let w = ceil(w)
        if w != chipWidth {
            chipWidth = w
            setFrameSize(NSSize(width: w, height: 30))
            invalidateIntrinsicContentSize()
        }
        needsDisplay = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: chipWidth, height: 30) }

    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (isHighlighted ? NSColor(white: 0.25, alpha: 1) : chipBG).setFill()
        p.fill()
        if let b = border {
            b.setStroke()
            p.lineWidth = 1
            p.stroke()
        }
        drawContent(r)
    }
    func drawContent(_ r: NSRect) {}

    /// Two text lines stacked in a 30pt bar.
    func drawTwoLines(_ top: NSAttributedString, _ bottom: NSAttributedString, x: CGFloat, in r: NSRect) {
        let by = r.minY + 3
        bottom.draw(at: NSPoint(x: x, y: by))
        top.draw(at: NSPoint(x: x, y: by + bottom.size().height - 3.5))
    }
}

// MARK: - overview: one chip per provider

final class ProviderChip: Chip {
    var usage: ProviderUsage { didSet { relayout() } }
    private var big = attr("…", 12), small = attr("", 9)
    private let barW: CGFloat = 26

    init(_ u: ProviderUsage) { usage = u; super.init(); relayout() }
    required init?(coder: NSCoder) { fatalError() }

    /// the window that limits you first
    var binding: UsageWindow? {
        let ws = [usage.session, usage.weekly].compactMap { $0 }
        return ws.max { $0.used < $1.used }
    }

    private func relayout() {
        switch usage.state {
        case .ok:
            if let b = binding {
                let sev = severityColor(b.used)
                big = attr(pct(b.used), 12.5, .bold, sev ?? usage.id.color, mono: true)
                small = attr((b.label == "wk" ? "wk " : "") + "↻" + fmtLeft(b.secondsLeft), 9, .medium, dimText, mono: true)
            }
            border = (binding.map { $0.used >= 0.9 } ?? false) ? NSColor.systemRed.withAlphaComponent(0.7) : nil
        case .loading:
            big = attr("…", 12.5, .bold, faintText); small = attr("loading", 9, .medium, faintText); border = nil
        case .authExpired(let why):
            big = attr("login", 11, .semibold, .systemOrange)
            small = attr("tap to fix", 9, .medium, dimText)
            border = NSColor.systemOrange.withAlphaComponent(0.5)
        case .failed:
            big = attr("—", 12.5, .bold, faintText); small = attr("offline", 9, .medium, faintText); border = nil
        }
        setWidth(7 + 14 + 6 + barW + 6 + max(big.size().width, small.size().width) + 8)
    }

    override func drawContent(_ r: NSRect) {
        let mid = r.midY
        let ok = usage.state == .ok
        Logo.draw(usage.id, center: CGPoint(x: r.minX + 7 + 7, y: mid), size: 14,
                  color: ok ? usage.id.color : faintText)
        let bx = r.minX + 7 + 14 + 6
        if ok {
            let s = usage.session, w = usage.weekly
            if let s, let w {
                drawBar(NSRect(x: bx, y: mid + 1.5, width: barW, height: 4), used: s.used,
                        color: severityColor(s.used) ?? usage.id.color)
                drawBar(NSRect(x: bx, y: mid - 5.5, width: barW, height: 4), used: w.used,
                        color: (severityColor(w.used) ?? usage.id.color).withAlphaComponent(0.65))
            } else if let one = s ?? w {
                drawBar(NSRect(x: bx, y: mid - 2.5, width: barW, height: 5), used: one.used,
                        color: severityColor(one.used) ?? usage.id.color)
            }
        } else {
            drawBar(NSRect(x: bx, y: mid - 2, width: barW, height: 4), used: 0, color: faintText)
        }
        drawTwoLines(big, small, x: bx + barW + 6, in: r)
    }
}

// MARK: - overview: Hermes at a glance

final class HermesChip: Chip {
    var sessions: [HermesSession] = [] { didSet { relayout() } }
    private var top = attr("Hermes", 11), bottom = attr("", 9)
    private var dot: HermesSession.Status? = nil
    private let maxW: CGFloat = 175

    override init() { super.init(); relayout() }
    required init?(coder: NSCoder) { fatalError() }

    private func relayout() {
        let working = sessions.filter { $0.status == .working }
        let done = sessions.filter { $0.status == .done }
        let textW = maxW - 30
        if let w = working.first {
            dot = .working
            top = fit(w.title, 11, .semibold, .white, maxW: textW)
            var tail = "\(w.activity) · \(fmtElapsed(w.since))"
            if working.count > 1 { tail += "  +\(working.count - 1) more" }
            bottom = fit(tail, 9, .medium, workingGreen.withAlphaComponent(0.9), maxW: textW)
        } else if let d = done.first {
            dot = .done
            top = fit(d.title, 11, .semibold, .white, maxW: textW)
            var tail = "done \(fmtAgo(Date().timeIntervalSince(d.since)))"
            if done.count > 1 { tail += "  +\(done.count - 1)" }
            bottom = fit(tail, 9, .medium, doneBlue, maxW: textW)
        } else {
            dot = sessions.isEmpty ? nil : .idle
            top = attr("Hermes", 11, .semibold, dimText)
            bottom = attr(sessions.isEmpty ? "no sessions" : "idle · \(sessions.count) sessions", 9, .medium, faintText)
        }
        setWidth(min(maxW, 22 + max(top.size().width, bottom.size().width) + 10))
    }

    override func drawContent(_ r: NSRect) {
        drawStatusMark(dot, at: CGPoint(x: r.minX + 12, y: r.midY))
        drawTwoLines(top, bottom, x: r.minX + 22, in: r)
    }
}

func drawStatusMark(_ s: HermesSession.Status?, at c: CGPoint) {
    switch s {
    case .working:
        // heartbeat: soft halo that breathes with the 1s tick
        let phase = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 2) < 1
        workingGreen.withAlphaComponent(phase ? 0.35 : 0.12).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11)).fill()
        workingGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
    case .done:
        let p = NSBezierPath()
        p.move(to: CGPoint(x: c.x - 3.5, y: c.y))
        p.line(to: CGPoint(x: c.x - 1, y: c.y - 2.8))
        p.line(to: CGPoint(x: c.x + 3.8, y: c.y + 3))
        p.lineWidth = 1.8
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        doneBlue.setStroke()
        p.stroke()
    case .idle:
        faintText.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)).fill()
    case nil:
        NSColor(white: 0.3, alpha: 1).setStroke()
        let p = NSBezierPath(ovalIn: NSRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))
        p.lineWidth = 1
        p.stroke()
    }
}

// MARK: - detail mode

final class BackChip: Chip {
    override init() { super.init(); setWidth(34) }
    required init?(coder: NSCoder) { fatalError() }
    override func drawContent(_ r: NSRect) {
        let a = attr("‹", 17, .semibold, .white)
        let s = a.size()
        a.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2 + 1))
    }
}

final class HeaderChip: Chip {
    var usage: ProviderUsage? { didSet { relayout() } }
    private var top = attr("", 12), bottom = attr("", 9)
    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError() }

    private func relayout() {
        guard let u = usage else { return }
        top = attr(u.id.name, 12, .bold, u.id.color)
        let ago = u.fetchedAt == .distantPast ? "" : " · \(fmtAgo(Date().timeIntervalSince(u.fetchedAt)))"
        bottom = attr((u.plan.isEmpty ? "plan" : u.plan) + ago, 9, .medium, dimText)
        setWidth(8 + 17 + 8 + max(top.size().width, bottom.size().width) + 10)
    }
    override func drawContent(_ r: NSRect) {
        guard let u = usage else { return }
        Logo.draw(u.id, center: CGPoint(x: r.minX + 8 + 8.5, y: r.midY), size: 17, color: u.id.color)
        drawTwoLines(top, bottom, x: r.minX + 33, in: r)
    }
}

final class WindowChip: Chip {
    private var win: UsageWindow?
    private var color: NSColor = .white
    private var label = attr("", 9.5), big = attr("", 12), bottom = attr("", 9)
    private let barW: CGFloat = 92

    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ w: UsageWindow?, name: String, color c: NSColor, key: String, message: String? = nil) {
        win = w
        color = c
        label = attr(name, 9.5, .semibold, dimText)
        guard let w else {
            big = attr("", 12)
            bottom = attr(message ?? "no data", 9, .medium, faintText)
            setWidth(10 + max(label.size().width + 6 + barW, bottom.size().width) + 10)
            return
        }
        big = attr(pct(w.used), 12.5, .bold, severityColor(w.used) ?? c, mono: true)
        var resetTxt = "resets in \(fmtLeft(w.secondsLeft))"
        if let r = w.resetsAt, (w.secondsLeft ?? 0) < 86400 { resetTxt += " · \(clock(r))" }
        bottom = attr(resetTxt, 9, .medium, dimText, mono: true)
        let topW = label.size().width + 6 + barW + 7 + big.size().width
        setWidth(10 + max(topW, bottom.size().width) + 10)
    }


    override func drawContent(_ r: NSRect) {
        let by = r.minY + 3
        bottom.draw(at: NSPoint(x: r.minX + 10, y: by))
        let rowY = by + bottom.size().height - 2
        label.draw(at: NSPoint(x: r.minX + 10, y: rowY + 1))
        let bx = r.minX + 10 + label.size().width + 6
        if let w = win {
            drawBar(NSRect(x: bx, y: rowY + 4.5, width: barW, height: 5), used: w.used,
                    color: severityColor(w.used) ?? color, tick: w.elapsed)
            big.draw(at: NSPoint(x: bx + barW + 7, y: rowY - 0.5))
        }
    }
}

final class ExtrasChip: Chip {
    private var lines: [NSAttributedString] = []
    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ items: [String]) {
        lines = items.prefix(2).map { attr($0, 9.5, .medium, dimText) }
        if lines.isEmpty { lines = [attr("↻ refresh", 10.5, .medium, dimText)] }
        setWidth(10 + (lines.map { $0.size().width }.max() ?? 40) + 10)
    }
    override func drawContent(_ r: NSRect) {
        if lines.count == 2 { drawTwoLines(lines[0], lines[1], x: r.minX + 10, in: r); return }
        if let l = lines.first { l.draw(at: NSPoint(x: r.minX + 10, y: r.midY - l.size().height / 2)) }
    }
}

// MARK: - sessions mode

final class SessionChip: Chip {
    let session: HermesSession
    private var top = attr("", 11), bottom = attr("", 9)

    init(_ s: HermesSession) {
        session = s
        super.init()
        top = fit(s.title, 11, .semibold, .white, maxW: 150)
        let b: String
        let c: NSColor
        switch s.status {
        case .working: b = "\(s.activity) · \(fmtElapsed(s.since))"; c = workingGreen
        case .done: b = "done \(fmtAgo(Date().timeIntervalSince(s.since)))"; c = doneBlue
        case .idle: b = "idle \(fmtAgo(Date().timeIntervalSince(s.since)))"; c = faintText
        }
        bottom = fit(b, 9, .medium, c, maxW: 150)
        border = s.status == .working ? workingGreen.withAlphaComponent(0.45) : nil
        setWidth(22 + max(top.size().width, bottom.size().width) + 10)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawContent(_ r: NSRect) {
        drawStatusMark(session.status, at: CGPoint(x: r.minX + 12, y: r.midY))
        drawTwoLines(top, bottom, x: r.minX + 22, in: r)
    }
}

/// Horizontally swipeable strip of session chips.
final class SessionsStrip: NSScrollView {
    private let stack = NSStackView()
    private var stripWidth: CGFloat = 200
    var maxWidth: CGFloat = 600

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        hasHorizontalScroller = false
        hasVerticalScroller = false
        drawsBackground = false
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        documentView = stack
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: stripWidth, height: 30) }

    func update(_ sessions: [HermesSession], onTap: @escaping (HermesSession) -> Void) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if sessions.isEmpty {
            let empty = Chip()
            let a = attr("no active Hermes sessions", 10.5, .medium, faintText)
            empty.setWidth(a.size().width + 20)
            empty.isEnabled = false
            stack.addArrangedSubview(empty)
            let label = NSTextField(labelWithAttributedString: a)
            label.frame.origin = NSPoint(x: 10, y: 15 - a.size().height / 2)
            empty.addSubview(label)
        }
        for s in sessions {
            let c = SessionChip(s)
            c.onTap = { onTap(s) }
            c.widthAnchor.constraint(equalToConstant: c.chipWidth).isActive = true
            c.heightAnchor.constraint(equalToConstant: 30).isActive = true
            stack.addArrangedSubview(c)
        }
        let content = stack.arrangedSubviews.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
            + stack.spacing * CGFloat(max(0, stack.arrangedSubviews.count - 1))
        stack.frame = NSRect(x: 0, y: 0, width: content, height: 30)
        stripWidth = min(maxWidth, content)
        setFrameSize(NSSize(width: stripWidth, height: 30))
        invalidateIntrinsicContentSize()
        contentView.scroll(to: .zero)
    }
}
