import AppKit

// "AI Tools" chip: switches for the non-chat local AI tools (~/Code/local-ai/extras).
// Reads ~/Code/local-ai/extras.json (written by the script) - no subprocess while polling.

struct ExtraTool {
    let key: String, title: String, detail: String
}

final class Extras {
    static let dir = NSString(string: "~/Code/local-ai").expandingTildeInPath
    // Add future tools here (tts, image gen, ...) once their on/off is wired in the extras script.
    let tools = [ExtraTool(key: "stt", title: "Speech to text", detail: "Whisper · voice messages")]
    private(set) var state: [String: Bool] = [:]
    private(set) var busy: String? = nil
    var onChange: (() -> Void)?

    func poll() {
        guard busy == nil,
              let d = FileManager.default.contents(atPath: Extras.dir + "/extras.json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return }
        let new = j.mapValues { $0 == "on" }
        if new != state { state = new; onChange?() }
    }

    func isOn(_ key: String) -> Bool { state[key] ?? false }

    func toggle(_ key: String) {
        guard busy == nil else { return }
        let target = isOn(key) ? "off" : "on"
        busy = key
        onChange?()
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [Extras.dir + "/extras", key, target]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { NSLog("[LimitBar] extras failed: %@", "\(error)") }
            NSLog("[LimitBar] extras %@ %@ exit %d", key, target, p.terminationStatus)
            DispatchQueue.main.async { self.busy = nil; self.poll(); self.onChange?() }
        }
    }

    /// One-line summary for the overview chip.
    var summary: String {
        if busy != nil { return "switching…" }
        let on = tools.filter { isOn($0.key) }
        if on.isEmpty { return "all off" }
        return on.map { $0.key == "stt" ? "Whisper on" : "\($0.title) on" }.joined(separator: " · ")
    }
}

let toolTeal = NSColor(red: 0.35, green: 0.85, blue: 0.80, alpha: 1)

/// Overview chip next to Local AI.
final class ToolsChip: Chip {
    var extras: Extras? { didSet { relayout() } }
    private var top = attr("AI Tools", 11), bottom = attr("", 9)

    override init() { super.init(); relayout() }
    required init?(coder: NSCoder) { fatalError() }

    func relayout() {
        let anyOn = extras.map { e in e.tools.contains { e.isOn($0.key) } } ?? false
        top = attr("AI Tools", 11, .semibold, anyOn ? .white : dimText)
        bottom = attr(extras?.summary ?? "", 9, .medium, anyOn ? toolTeal : faintText)
        border = anyOn ? toolTeal.withAlphaComponent(0.4) : nil
        setWidth(22 + max(top.size().width, bottom.size().width) + 10)
        needsDisplay = true
    }

    override func drawContent(_ r: NSRect) {
        // tiny 2x2 grid glyph = "tools"
        let c = CGPoint(x: r.minX + 12, y: r.midY)
        let anyOn = extras.map { e in e.tools.contains { e.isOn($0.key) } } ?? false
        (anyOn ? toolTeal : NSColor(white: 0.4, alpha: 1)).setFill()
        for (dx, dy) in [(-3.5, 0.5), (0.5, 0.5), (-3.5, -3.5), (0.5, -3.5)] {
            NSBezierPath(roundedRect: NSRect(x: c.x + dx, y: c.y + dy, width: 3, height: 3), xRadius: 0.8, yRadius: 0.8).fill()
        }
        drawTwoLines(top, bottom, x: r.minX + 22, in: r)
    }
}

/// One tool in the AI Tools row: tap to switch it on/off.
final class ToolToggleChip: Chip {
    let tool: ExtraTool
    weak var extras: Extras?
    private var top = attr("", 11), bottom = attr("", 9)

    init(_ t: ExtraTool, _ e: Extras) {
        tool = t; extras = e
        super.init()
        relayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    func relayout() {
        let on = extras?.isOn(tool.key) ?? false
        let busy = extras?.busy == tool.key
        top = attr(tool.title, 11, .semibold, .white)
        bottom = attr(busy ? "switching…" : (on ? "on · tap to turn off" : "off · tap to turn on"), 9, .medium,
                      busy ? dimText : (on ? toolTeal : faintText))
        border = on ? toolTeal.withAlphaComponent(0.45) : NSColor(white: 1, alpha: 0.08)
        setWidth(40 + max(top.size().width, bottom.size().width) + 10)
        needsDisplay = true
    }

    override func drawContent(_ r: NSRect) {
        // small switch glyph
        let on = extras?.isOn(tool.key) ?? false
        let track = NSRect(x: r.minX + 8, y: r.midY - 5, width: 20, height: 10)
        (on ? toolTeal.withAlphaComponent(0.85) : NSColor(white: 0.25, alpha: 1)).setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        NSColor.white.setFill()
        let knobX = on ? track.maxX - 9 : track.minX + 1
        NSBezierPath(ovalIn: NSRect(x: knobX, y: track.minY + 1, width: 8, height: 8)).fill()
        drawTwoLines(top, bottom, x: r.minX + 36, in: r)
    }
}

/// Label at the start of the AI Tools row.
final class ToolsHeader: Chip {
    private let a = attr("AI Tools:", 11, .medium, dimText)
    override init() { super.init(); setWidth(a.size().width + 16) }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let s = a.size()
        a.draw(at: NSPoint(x: 8, y: bounds.midY - s.height / 2))
    }
}
