import AppKit

// "AI Tools" chip: switches for the non-chat local AI tools (~/Code/local-ai/extras).
// Reads ~/Code/local-ai/extras.json (written by the script) - no subprocess while polling.

struct ExtraTool {
    let key: String, title: String, detail: String
}

final class Extras {
    static let dir = NSString(string: "~/Code/local-ai").expandingTildeInPath
    // Add future tools here (tts, image gen, ...) once their on/off is wired in the extras script.
    let tools = [ExtraTool(key: "stt", title: "Speech to text", detail: "Whisper · voice messages"),
                 ExtraTool(key: "tts", title: "Text to speech", detail: "Piper · ID + EN auto"),
                 ExtraTool(key: "image", title: "Image gen", detail: "FLUX.2 Klein"),
                 ExtraTool(key: "upscale", title: "Upscale", detail: "SeedVR2"),
                 ExtraTool(key: "video", title: "Video gen", detail: "local video"),
                 ExtraTool(key: "music", title: "Music gen", detail: "ACE-Step"),
                 ExtraTool(key: "3d", title: "3D gen", detail: "Hunyuan3D"),
                 ExtraTool(key: "bgremove", title: "Remove BG", detail: "background remover"),
                 ExtraTool(key: "voiceclean", title: "Clean voice", detail: "noise removal"),
                 ExtraTool(key: "stems", title: "Vocal split", detail: "vocal / music split"),
                 ExtraTool(key: "captions", title: "Captions", detail: "auto subtitles"),
                 ExtraTool(key: "search", title: "File search", detail: "local search"),
                 ExtraTool(key: "reframe", title: "Reframe", detail: "16:9 to vertical"),
                 ExtraTool(key: "videobg", title: "Video BG", detail: "video background removal"),
                 ExtraTool(key: "videoupscale", title: "Video upscale", detail: "sharpen video"),
                 ExtraTool(key: "voiceclone", title: "Voice clone", detail: "your voice"),
                 ExtraTool(key: "dub", title: "Dubbing", detail: "ID / EN dub")]
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
        // keep this short: a wider chip overflows the Touch Bar and hides the other chips
        if on.count > 2 { return "\(on.count) on" }  // more than two would widen the chip and overflow the bar
        let short = ["stt": "STT", "tts": "TTS", "image": "IMG", "upscale": "UPS", "video": "VID", "music": "MUS", "3d": "3D",
                     "bgremove": "CUT", "voiceclean": "CLN", "stems": "STM", "captions": "CAP", "search": "SRCH",
                     "reframe": "RFR", "videobg": "VBG", "videoupscale": "VUP", "voiceclone": "VOX", "dub": "DUB"]
        return on.map { short[$0.key] ?? $0.key.uppercased() }.joined(separator: " · ")
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
        bottom = attr(busy ? "switching…" : (on ? "on" : "off"), 9, .medium,
                      busy ? dimText : (on ? toolTeal : faintText))
        border = on ? toolTeal.withAlphaComponent(0.45) : NSColor(white: 1, alpha: 0.08)
        // fixed width (widest possible subtitle) so the chip never resizes inside the scrolling strip
        let widest = attr("switching…", 9, .medium, dimText).size().width
        setWidth(34 + max(top.size().width, widest) + 8)
        needsDisplay = true
    }

    override func drawContent(_ r: NSRect) {
        // small switch glyph
        let on = extras?.isOn(tool.key) ?? false
        let track = NSRect(x: r.minX + 7, y: r.midY - 5, width: 18, height: 10)
        (on ? toolTeal.withAlphaComponent(0.85) : NSColor(white: 0.25, alpha: 1)).setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        NSColor.white.setFill()
        let knobX = on ? track.maxX - 9 : track.minX + 1
        NSBezierPath(ovalIn: NSRect(x: knobX, y: track.minY + 1, width: 8, height: 8)).fill()
        drawTwoLines(top, bottom, x: r.minX + 30, in: r)
    }
}

/// Swipeable row with every tool toggle (more tools than fit on the Touch Bar at once).
final class ToolsStrip: NSScrollView {
    private let stack = NSStackView()
    private var stripWidth: CGFloat = 200
    var maxWidth: CGFloat = 640

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

    func update(_ chips: [ToolToggleChip]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for c in chips {
            c.translatesAutoresizingMaskIntoConstraints = false
            c.widthAnchor.constraint(equalToConstant: c.chipWidth).isActive = true
            c.heightAnchor.constraint(equalToConstant: 30).isActive = true
            stack.addArrangedSubview(c)
        }
        let content = chips.reduce(CGFloat(0)) { $0 + $1.chipWidth } + stack.spacing * CGFloat(max(0, chips.count - 1))
        stack.frame = NSRect(x: 0, y: 0, width: content, height: 30)
        stripWidth = min(maxWidth, content)
        setFrameSize(NSSize(width: stripWidth, height: 30))
        invalidateIntrinsicContentSize()
        contentView.scroll(to: .zero)
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
