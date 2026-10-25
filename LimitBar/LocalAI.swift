import AppKit

// Local AI switch: Ollama + the Bad Rudy adapter (~/Code/bad-rudy/localai).
// Polls localhost directly (no subprocess) and toggles through the script.

enum LocalAIState: Equatable {
    case off, on(mem: String), busy(String), partial
}

final class LocalAI {
    static let script = NSString(string: "~/Code/bad-rudy/localai").expandingTildeInPath
    private(set) var state: LocalAIState = .off
    var onChange: ((LocalAIState) -> Void)?
    private var busy = false

    private func get(_ url: String, _ done: @escaping (Data?) -> Void) {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 1
        URLSession.shared.dataTask(with: req) { d, r, _ in
            done((r as? HTTPURLResponse)?.statusCode == 200 ? d : nil)
        }.resume()
    }

    func poll() {
        guard !busy else { return }
        let g = DispatchGroup()
        var ps: Data?, adapter = false
        g.enter(); get("http://127.0.0.1:11434/api/ps") { ps = $0; g.leave() }
        g.enter(); get("http://127.0.0.1:11435/health") { adapter = $0 != nil; g.leave() }
        g.notify(queue: .main) { [weak self] in
            guard let self, !self.busy else { return }
            let new: LocalAIState
            if let ps, adapter {
                var mem = "idle"
                if let j = try? JSONSerialization.jsonObject(with: ps) as? [String: Any],
                   let models = j["models"] as? [[String: Any]], !models.isEmpty {
                    let bytes = models.compactMap { ($0["size_vram"] as? Double) ?? ($0["size"] as? Double) }.reduce(0, +)
                    mem = String(format: "%.1f GB", bytes / 1_073_741_824)
                }
                new = .on(mem: mem)
            } else if ps != nil || adapter {
                new = .partial
            } else {
                new = .off
            }
            self.set(new)
        }
    }

    func toggle() {
        guard !busy else { return }
        let turningOn: Bool = { if case .off = state { return true }; return false }()
        busy = true
        set(.busy(turningOn ? "starting" : "stopping"), force: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [LocalAI.script, turningOn ? "on" : "off"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { NSLog("[LimitBar] localai failed: %@", "\(error)") }
            NSLog("[LimitBar] localai %@ exit %d", turningOn ? "on" : "off", p.terminationStatus)
            DispatchQueue.main.async { self.busy = false; self.poll() }
        }
    }

    private func set(_ s: LocalAIState, force: Bool = false) {
        guard force || s != state else { return }
        state = s
        onChange?(s)
    }
}

final class LocalAIChip: Chip {
    var aiState: LocalAIState = .off { didSet { relayout() } }
    private var top = attr("Local AI", 11), bottom = attr("off", 9)
    private let localPurple = NSColor(red: 0.62, green: 0.52, blue: 1.0, alpha: 1)

    override init() { super.init(); relayout() }
    required init?(coder: NSCoder) { fatalError() }

    private func relayout() {
        switch aiState {
        case .off:
            top = attr("Local AI", 11, .semibold, dimText)
            bottom = attr("off", 9, .medium, faintText)
            border = nil
        case .on(let mem):
            top = attr("Local AI", 11, .semibold, .white)
            bottom = attr("on · \(mem)", 9, .medium, localPurple, mono: true)
            border = localPurple.withAlphaComponent(0.45)
        case .busy(let what):
            top = attr("Local AI", 11, .semibold, .white)
            bottom = attr("\(what)…", 9, .medium, dimText)
            border = nil
        case .partial:
            top = attr("Local AI", 11, .semibold, .systemOrange)
            bottom = attr("tap to reset", 9, .medium, dimText)
            border = NSColor.systemOrange.withAlphaComponent(0.5)
        }
        setWidth(22 + max(top.size().width, bottom.size().width) + 10)
    }

    override func drawContent(_ r: NSRect) {
        let c = CGPoint(x: r.minX + 12, y: r.midY)
        switch aiState {
        case .on:
            localPurple.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)).fill()
        case .busy:
            let phase = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1) < 0.5
            localPurple.withAlphaComponent(phase ? 0.9 : 0.3).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
        case .partial:
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
        case .off:
            NSColor(white: 0.35, alpha: 1).setStroke()
            let p = NSBezierPath(ovalIn: NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
            p.lineWidth = 1.2
            p.stroke()
        }
        drawTwoLines(top, bottom, x: r.minX + 22, in: r)
    }
}
