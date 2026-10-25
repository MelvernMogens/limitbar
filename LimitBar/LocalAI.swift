import AppKit

// Local AI switch: Ollama + the local adapter (~/Code/local-ai/localai).
// Models come from ~/Code/local-ai/models.json (shared with the adapter and the script).
// Polls localhost directly (no subprocess); starts/stops through the script.

struct LocalModel {
    let id: String, label: String, short: String, ram: String
}

enum LocalAIState: Equatable {
    case off, on(model: String, mem: String), busy(String), partial
}

final class LocalAI {
    static let dir = NSString(string: "~/Code/local-ai").expandingTildeInPath
    static let script = dir + "/localai"
    private(set) var state: LocalAIState = .off
    private(set) var models: [LocalModel] = []
    var onChange: ((LocalAIState) -> Void)?
    private var busy = false

    init() { reloadModels() }

    func reloadModels() {
        guard let d = FileManager.default.contents(atPath: LocalAI.dir + "/models.json"),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
        models = arr.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let label = m["label"] as? String ?? id
            return LocalModel(id: id, label: label, short: m["short"] as? String ?? label, ram: m["ram"] as? String ?? "")
        }
    }

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
        var ps: Data?, health: Data?
        g.enter(); get("http://127.0.0.1:11434/api/ps") { ps = $0; g.leave() }
        g.enter(); get("http://127.0.0.1:11435/health") { health = $0; g.leave() }
        g.notify(queue: .main) { [weak self] in
            guard let self, !self.busy else { return }
            let new: LocalAIState
            if let ps, let health {
                var mem = "idle"
                if let j = try? JSONSerialization.jsonObject(with: ps) as? [String: Any],
                   let ms = j["models"] as? [[String: Any]], !ms.isEmpty {
                    let bytes = ms.compactMap { ($0["size_vram"] as? Double) ?? ($0["size"] as? Double) }.reduce(0, +)
                    mem = String(format: "%.1f GB", bytes / 1_073_741_824)
                }
                let id = ((try? JSONSerialization.jsonObject(with: health)) as? [String: Any])?["model"] as? String ?? ""
                let name = self.models.first { $0.id == id }?.short ?? (id.isEmpty ? "on" : id)
                new = .on(model: name, mem: mem)
            } else if ps != nil || health != nil {
                new = .partial
            } else {
                new = .off
            }
            self.set(new)
        }
    }

    func start(_ id: String) { run(["on", id], busyText: "starting") }
    func stop() { run(["off"], busyText: "stopping") }

    private func run(_ args: [String], busyText: String) {
        guard !busy else { return }
        busy = true
        set(.busy(busyText), force: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [LocalAI.script] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { NSLog("[LimitBar] localai failed: %@", "\(error)") }
            NSLog("[LimitBar] localai %@ exit %d", args.joined(separator: " "), p.terminationStatus)
            DispatchQueue.main.async { self.busy = false; self.poll() }
        }
    }

    private func set(_ s: LocalAIState, force: Bool = false) {
        guard force || s != state else { return }
        state = s
        onChange?(s)
    }
}

let localPurple = NSColor(red: 0.62, green: 0.52, blue: 1.0, alpha: 1)

final class LocalAIChip: Chip {
    var aiState: LocalAIState = .off { didSet { relayout() } }
    private var top = attr("Local AI", 11), bottom = attr("off", 9)

    override init() { super.init(); relayout() }
    required init?(coder: NSCoder) { fatalError() }

    private func relayout() {
        switch aiState {
        case .off:
            top = attr("Local AI", 11, .semibold, dimText)
            bottom = attr("off", 9, .medium, faintText)
            border = nil
        case .on(let model, let mem):
            top = attr(model, 11, .semibold, .white)
            bottom = attr("on · \(mem)", 9, .medium, localPurple, mono: true)
            border = localPurple.withAlphaComponent(0.45)
        case .busy(let what):
            top = attr("Local AI", 11, .semibold, .white)
            bottom = attr("\(what)…", 9, .medium, dimText)
            border = nil
        case .partial:
            top = attr("Local AI", 11, .semibold, dimText)
            bottom = attr("ollama only · pick", 9, .medium, faintText)
            border = nil
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
            NSColor(white: 0.45, alpha: 1).setFill()
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

/// One choice in the model picker: name on top, memory it will use below.
final class LocalModelChip: Chip {
    let model: LocalModel
    private let top: NSAttributedString, bottom: NSAttributedString

    init(_ m: LocalModel) {
        model = m
        top = attr(m.label, 11, .semibold, .white)
        bottom = attr(m.ram.isEmpty ? "start" : "start · \(m.ram)", 9, .medium, localPurple, mono: true)
        super.init()
        border = localPurple.withAlphaComponent(0.3)
        setWidth(22 + max(top.size().width, bottom.size().width) + 10)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawContent(_ r: NSRect) {
        let c = CGPoint(x: r.minX + 12, y: r.midY)
        // play triangle
        let p = NSBezierPath()
        p.move(to: CGPoint(x: c.x - 2.5, y: c.y - 4))
        p.line(to: CGPoint(x: c.x + 4, y: c.y))
        p.line(to: CGPoint(x: c.x - 2.5, y: c.y + 4))
        p.close()
        localPurple.setFill()
        p.fill()
        drawTwoLines(top, bottom, x: r.minX + 22, in: r)
    }
}

/// Small label at the start of the picker row.
final class LocalPickHeader: Chip {
    private let a = attr("Start local AI:", 11, .medium, dimText)
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
