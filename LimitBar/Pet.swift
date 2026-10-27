import AppKit

// MARK: - Candie, the Touch Bar toy poodle
// A tiny pixel dog that lives next to the stats chip. It walks around on its own, sleeps at night,
// and asks for things with a little bubble when it needs them. Ignore it and it gets sad, then sick.
// Tap it to Feed / Play / Pet (and Medicine when sick). Drawn in code (no images); ~1 MB, <1% CPU.

final class Pet {
    static let shared = Pet()
    let name = "Candie"
    private let d = UserDefaults.standard

    var hunger: Double { didSet { save() } }   // 100 = full, 0 = starving
    var fun: Double { didSet { save() } }      // 100 = very happy
    var health: Double { didSet { save() } }   // 100 = healthy
    var sick: Bool { didSet { save() } }
    var dirt: Double { didSet { save() } }     // 0 = clean, 100 = filthy
    var poops: Int { didSet { save() } }
    var bond: Double { didSet { save() } }     // grows with daily care
    var streak: Int { didSet { save() } }      // days in a row you cared for her
    var outfit: String { didSet { save() } }   // none, bow, glasses, scarf, crown, santa
    private var nextPoop: Date
    private var lastCareDay: String
    private var last: Date

    enum Act { case feed, play, pat, med, clean, bath, zoom, greet, celebrate, mail, dress }
    /// short-lived reaction (an animation in the yard) + optional words in a bubble
    var reaction: (kind: Act, icon: String, until: Date)?
    var saying: (text: String, until: Date)?

    // live Mac mood (set from LimitBar's stats every 2 s; not saved)
    var cpuHot = false, ramFull = false, batteryLow = false

    private init() {
        hunger = d.object(forKey: "pet.hunger") as? Double ?? 80
        fun = d.object(forKey: "pet.fun") as? Double ?? 80
        health = d.object(forKey: "pet.health") as? Double ?? 100
        sick = d.bool(forKey: "pet.sick")
        dirt = d.object(forKey: "pet.dirt") as? Double ?? 10
        poops = d.integer(forKey: "pet.poops")
        bond = d.double(forKey: "pet.bond")
        streak = d.integer(forKey: "pet.streak")
        outfit = d.string(forKey: "pet.outfit") ?? "none"
        nextPoop = Date(timeIntervalSince1970: d.double(forKey: "pet.nextPoop"))
        lastCareDay = d.string(forKey: "pet.lastCareDay") ?? ""
        last = Date(timeIntervalSince1970: d.double(forKey: "pet.last"))
        if d.double(forKey: "pet.last") == 0 { last = Date() }
        if d.double(forKey: "pet.nextPoop") == 0 { nextPoop = Date().addingTimeInterval(3 * 3600) }
        update()
    }

    private func save() {
        d.set(hunger, forKey: "pet.hunger"); d.set(fun, forKey: "pet.fun")
        d.set(health, forKey: "pet.health"); d.set(sick, forKey: "pet.sick")
        d.set(dirt, forKey: "pet.dirt"); d.set(poops, forKey: "pet.poops")
        d.set(bond, forKey: "pet.bond"); d.set(streak, forKey: "pet.streak"); d.set(outfit, forKey: "pet.outfit")
    }

    var asleep: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return (h >= 23 || h < 7) && reaction == nil
    }

    // MARK: bond + outfits
    static let levelAt: [Double] = [0, 20, 50, 100, 180, 300]
    var level: Int { (Pet.levelAt.lastIndex { bond >= $0 } ?? 0) + 1 }
    var nextLevelProgress: Double {
        let l = level
        guard l < Pet.levelAt.count else { return 1 }
        let lo = Pet.levelAt[l - 1], hi = Pet.levelAt[l]
        return min(1, (bond - lo) / (hi - lo))
    }
    /// outfits unlocked by bond level (+ a Santa hat in December)
    var unlockedOutfits: [String] {
        var o = ["none"]
        if level >= 2 { o.append("bow") }
        if level >= 3 { o.append("glasses") }
        if level >= 4 { o.append("scarf") }
        if level >= 6 { o.append("crown") }
        if Calendar.current.component(.month, from: Date()) == 12 { o.append("santa") }
        return o
    }
    func dress() {
        let o = unlockedOutfits
        let i = ((o.firstIndex(of: outfit) ?? 0) + 1) % o.count
        outfit = o[i]
        react(.dress, outfit == "none" ? "✨" : "💅", 2.5)
    }
    private func cared(_ points: Double) {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        if lastCareDay != today {
            let yesterday = df.string(from: Date().addingTimeInterval(-86400))
            streak = lastCareDay == yesterday ? streak + 1 : 1
            lastCareDay = today; d.set(today, forKey: "pet.lastCareDay")
            bond += Double(min(streak, 7))                       // daily streak bonus
        }
        let before = level
        bond += points
        if level > before {
            let new = unlockedOutfits.last ?? "none"
            say("❤️ Lv \(level)!" + (new != "none" && new != "santa" ? " new outfit" : ""), 5)
        }
    }

    /// Needs change slowly over real time (also while LimitBar was closed).
    func update() {
        let now = Date()
        let hours = min(now.timeIntervalSince(last) / 3600, 48)   // cap: a long trip away doesn't wreck it
        last = now
        d.set(now.timeIntervalSince1970, forKey: "pet.last")
        if let r = reaction, r.until < now { reaction = nil }
        if let s = saying, s.until < now { saying = nil }
        guard hours > 0 else { return }
        let rate = asleep ? 0.4 : 1.0
        hunger = max(0, hunger - 6 * hours * rate)
        fun = max(0, fun - (5 + 2 * Double(poops) + (dirt > 70 ? 1.5 : 0)) * hours * rate)
        dirt = min(100, dirt + 2.5 * hours)
        if now >= nextPoop && !asleep {
            if poops < 3 { poops += 1 }
            nextPoop = now.addingTimeInterval(Double.random(in: 3...6) * 3600)
            d.set(nextPoop.timeIntervalSince1970, forKey: "pet.nextPoop")
        }
        if hunger < 20 || fun < 15 || poops >= 3 {
            health = max(0, health - 5 * hours)          // neglect wears her down
        } else if !sick {
            health = min(100, health + 4 * hours)
        }
        if !sick && health < 40 { sick = true }
    }

    /// What she wants right now (shown in a bubble), most urgent first.
    var need: String? {
        if sick { return "🤒 sick…" }
        if hunger < 35 { return "🍖 hungry!" }
        if poops > 0 { return "💩 clean pls" }
        if dirt >= 70 { return "🛁 bath?" }
        if fun < 35 { return "🎾 play?" }
        if fun < 50 && hunger < 50 { return "😢 sad" }
        if batteryLow { return "🔋 sleepy…" }
        if ramFull { return "😵 so full" }
        if cpuHot { return "🥵 hot!" }
        return nil
    }

    var moodWord: String {
        if sick { return "sick" }
        if asleep { return "sleeping" }
        if hunger < 35 { return "hungry" }
        if poops > 0 { return "needs cleaning" }
        if dirt >= 70 { return "dirty" }
        if fun < 35 { return "bored" }
        if fun > 75 && hunger > 60 { return "happy" }
        return "ok"
    }

    func feed() {
        hunger = min(100, hunger + 40); fun = min(100, fun + 3); cared(3)
        nextPoop = min(nextPoop, Date().addingTimeInterval(Double.random(in: 1...2) * 3600))   // what goes in…
        d.set(nextPoop.timeIntervalSince1970, forKey: "pet.nextPoop")
        react(.feed, "🍖", 4.5)
    }
    func play() { fun = min(100, fun + 35); hunger = max(0, hunger - 5); dirt = min(100, dirt + 15); cared(3); react(.play, "🎾", 6) }
    func pat() { fun = min(100, fun + 12); cared(1); react(.pat, "💕", 4) }
    func clean() { poops = 0; fun = min(100, fun + 5); cared(3); react(.clean, "✨", 3) }
    func bath() { dirt = 0; fun = min(100, fun + 4); cared(3); react(.bath, "🫧", 5) }
    func medicine() {
        health = min(100, health + 45)
        if health >= 50 { sick = false }
        cared(2)
        react(.med, "💊", 3)
    }
    func react(_ k: Act, _ icon: String, _ secs: Double) { reaction = (k, icon, Date().addingTimeInterval(secs)) }
    func say(_ text: String, _ secs: Double) { saying = (text, Date().addingTimeInterval(secs)) }

    // MARK: reacting to the Mac
    private var hotCount = 0, wasOnAC: Bool? = nil, awaySince: Date? = nil
    private var limitHigh: [String: Bool] = [:], limitWasUsed: [String: Double] = [:]
    private var workingIDs = Set<String>()

    /// Called every 2 s with what LimitBar already knows.
    func observe(cpu: Double, ramFrac: Double, pressure: Int, battery: Double?, charging: Bool, onAC: Bool,
                 idleSeconds: Double, limits: [(name: String, used: Double)], tasks: [(id: String, who: String, working: Bool)]) {
        hotCount = cpu > 0.80 ? hotCount + 1 : 0
        cpuHot = hotCount >= 3                                     // ~6 s of heavy CPU
        ramFull = pressure >= 4 || ramFrac > 0.93
        batteryLow = (battery ?? 1) < 0.2 && !charging && !onAC
        if let was = wasOnAC, !was, onAC, !asleep { react(.zoom, "⚡", 4); say("⚡ yay power!", 3) }
        wasOnAC = onAC
        // you went away and came back
        if idleSeconds > 300 { if awaySince == nil { awaySince = Date() } }
        else if awaySince != nil, idleSeconds < 5 {
            awaySince = nil
            if !asleep { react(.greet, "❤️", 4); say("❤️ you're back!", 4) }
        }
        // AI usage limits: whine near the limit, celebrate the reset
        for l in limits {
            let high = l.used >= 0.85
            if high, limitHigh[l.name] != true, !asleep { say("⚠️ \(l.name) \(Int(l.used * 100))%", 6) }
            limitHigh[l.name] = high
            if let was = limitWasUsed[l.name], was >= 0.5, l.used < 0.1, !asleep {
                react(.celebrate, "🎉", 4); say("🎉 \(l.name) reset!", 5)
            }
            limitWasUsed[l.name] = l.used
        }
        // a Hermes task finished: she brings the mail
        let nowWorking = Set(tasks.filter { $0.working }.map { $0.id })
        if let done = tasks.first(where: { workingIDs.contains($0.id) && !$0.working }) {
            react(.mail, "📬", 5); say("📬 \(done.who) done!", 6)
        }
        workingIDs = nowWorking
    }
}

// MARK: - the yard chip on the main bar

private struct Particle { var x: CGFloat; var y: CGFloat; var vx: CGFloat; var vy: CGFloat; var life: Int; let text: String; let size: CGFloat }

// brown toy poodle
private let FUR = NSColor(srgbRed: 0.60, green: 0.38, blue: 0.20, alpha: 1)        // coat
private let FUR_HI = NSColor(srgbRed: 0.74, green: 0.50, blue: 0.29, alpha: 1)     // curl highlights
private let FUR_SICK = NSColor(srgbRed: 0.62, green: 0.56, blue: 0.40, alpha: 1)
private let FUR_DARK = NSColor(srgbRed: 0.42, green: 0.25, blue: 0.12, alpha: 1)   // ears, far legs
private let CREAM = NSColor(srgbRed: 0.80, green: 0.62, blue: 0.44, alpha: 1)      // lighter muzzle
private let INK = NSColor(white: 0.10, alpha: 1)

/// Smooth vector puppy drawn from parts (body, legs, head, ears, tail) so each can move on its own.
final class PetChip: Chip {
    private let pet = Pet.shared
    private var x: CGFloat = 40            // dog position (left edge) in the yard, points
    private var dir: CGFloat = 1
    private var t: Double = 0              // seconds of animation time
    private var phase: Double = 0          // walk cycle
    private var tickN = 0
    private var pauseUntil = Date()
    private var timer: Timer?
    private let yard: CGFloat = 170
    private let dogW: CGFloat = 28
    private var particles: [Particle] = []
    private var ballX: CGFloat = 0, ballY: CGFloat = 0, ballVY: CGFloat = 0, ballVX: CGFloat = 0
    private var jumpY: CGFloat = 0, jumpV: CGFloat = 0
    private var earLag: CGFloat = 0        // ears follow the head with a delay
    private var lastHeadY: CGFloat = 0
    private var blinkUntil = 0.0, nextBlink = 3.0
    private var lastAct: Pet.Act? = nil
    private var front = false
    private var chaseV: CGFloat = 0
    private var poopXs: [CGFloat] = []      // where the poops are in the yard
    // smoothed pose: every change eases in over ~0.4 s instead of snapping
    private var sLegH: CGFloat = 5.2, sHX: CGFloat = 0, sHY: CGFloat = 0, sTail: CGFloat = 0.7, sWagAmp: CGFloat = 0.35
    private var sWagSpeed = 7.0, wagPhase = 0.0
    private var turnS: CGFloat = 0           // 0 = side view, 1 = facing you (turns through a squash)
    private var dirS: CGFloat = 1            // facing direction, eased so turning around is a flip, not a pop
    private var bowlA: CGFloat = 0, ballA: CGFloat = 0, bowlX: CGFloat = 0
    private var settling = false
    private var wasAsleep = false, yawnUntil = 0.0, stretchUntil = 0.0              // turned toward you (idle moments, being petted)

    override init() {
        super.init()
        setWidth(yard)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in self?.step() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var moving: Bool {
        settling || t < yawnUntil || t < stretchUntil || pet.reaction != nil || pet.saying != nil || (!(pet.asleep || pet.sick) && Date() >= pauseUntil) || !particles.isEmpty || jumpY > 0
    }

    private func step() {
        tickN += 1
        let dt = 1.0 / 12.0
        t += dt
        wagPhase += dt * sWagSpeed
        if tickN % 24 == 0 { pet.update() }
        let act = pet.reaction?.kind
        if act != lastAct { startAct(act); lastAct = act }
        if t > nextBlink { blinkUntil = t + 0.17; nextBlink = t + Double.random(in: 2.5...5.5) }

        switch act {
        case .feed?:
            if tickN % 11 == 0 { spawn(x + (dir > 0 ? dogW + CGFloat.random(in: -1...4) : CGFloat.random(in: -8...(-3))), 9, "•", 5, vy: 0.5, vx: CGFloat.random(in: -0.4...0.4)) }   // kibble bits
        case .play?:
            ballVY -= 0.75; ballY += ballVY; ballX += ballVX * 1.6
            if ballY <= 2.5 { ballY = 2.5; ballVY = 4.2 }
            let lo: CGFloat = 8, hi: CGFloat = yard - 12
            if ballX < lo { ballX = lo; ballVX = abs(ballVX) }
            if ballX > hi { ballX = hi; ballVX = -abs(ballVX) }
            // run toward a spot just behind the ball; only turn around when clearly needed (no left-right jitter)
            let mouth = x + (dir > 0 ? dogW - 3 : 3)
            let gap = ballX - mouth
            if gap * dir < -10 { dir = -dir }
            let want = max(-2.6, min(2.6, gap * 0.16))
            chaseV += (want - chaseV) * 0.25
            if abs(gap) > 4 { x += chaseV; phase += Double(abs(chaseV)) * 0.6 + 0.04 }
            if jumpY == 0 && abs(gap) < 14 && Int.random(in: 0..<45) == 0 { jumpV = 2.3 }
        case .pat?:
            if tickN % 10 == 0 { let side: CGFloat = Bool.random() ? 1 : -1; spawn(x + dogW / 2 + side * 12 - 3, 8, "♥", 7, vy: 0.32, vx: side * 0.2) }   // beside the head
        case .med?:
            if tickN % 9 == 0 { spawn(x + dogW * 0.6, 15, "+", 9, vy: 0.35) }
        case .clean?:
            if tickN % 4 == 0, let px = poopXs.randomElement() ?? Optional(x) { spawn(px + CGFloat.random(in: -2...4), 4, "✦", 7, vy: 0.4) }
            if tickN % 12 == 0, !poopXs.isEmpty { poopXs.removeLast() }       // scooped one by one
        case .bath?:
            if tickN % 2 == 0 { spawn(x + CGFloat.random(in: -2...dogW), CGFloat.random(in: 3...16), Bool.random() ? "○" : "●", CGFloat.random(in: 5...9), vy: 0.3, vx: CGFloat.random(in: -0.25...0.25)) }
        case .zoom?:                                                   // zoomies!
            x += dir * 2.2; phase += 1.3
            if x <= 4 || x >= yard - dogW - 4 { dir = -dir }
            if jumpY == 0 && Int.random(in: 0..<25) == 0 { jumpV = 2.0 }
        case .greet?, .celebrate?:
            if jumpY == 0 && tickN % 9 == 0 { jumpV = 1.7 }
            if act == .celebrate, tickN % 2 == 0 { spawn(CGFloat.random(in: 0...yard), CGFloat.random(in: 18...24), "✦", 6, vy: -0.4, vx: CGFloat.random(in: -0.3...0.3)) }
            if act == .greet, tickN % 10 == 0 { spawn(x + dogW / 2 + CGFloat.random(in: -12...10), 10, "♥", 7, vy: 0.3) }
        case .mail?, .dress?:
            if act == .dress, tickN % 5 == 0 { spawn(x + CGFloat.random(in: 0...dogW), CGFloat.random(in: 8...20), "✦", 6, vy: 0.2) }
        case nil:
            if !(pet.asleep || pet.sick) && Date() >= pauseUntil {
                let speed: CGFloat = (pet.fun < 35 || pet.batteryLow) ? 0.37 : 0.75   // points per frame (12 fps)
                x += dir * speed
                phase += Double(speed) * 0.62
                if x <= 3 || x >= yard - dogW - 3 { dir = -dir }
                if Int.random(in: 0..<400) == 0 {
                    pauseUntil = Date().addingTimeInterval(Double.random(in: 3...8))
                    front = Int.random(in: 0..<3) != 0          // usually turns to look at you
                    if !front && Bool.random() { dir = -dir }
                }
            } else if Date() < pauseUntil, front, Int.random(in: 0..<500) == 0 {
                front = false
            }
            if Date() >= pauseUntil && !(pet.asleep || pet.sick) { front = false }
            if pet.asleep && tickN % 40 == 0 { spawn(x + dogW - 2, 13, "z", 8, vy: 0.14, vx: 0.12) }
        }
        x = min(max(x, 3), yard - dogW - 3)
        if pet.reaction?.kind != .clean {
            if poopXs.count > pet.poops { poopXs.removeAll() }
            while poopXs.count < pet.poops { poopXs.append(CGFloat.random(in: 6...(yard - 12))) }
        }
        if jumpV != 0 || jumpY > 0 { jumpY += jumpV; jumpV -= 0.8; if jumpY <= 0 { jumpY = 0; jumpV = 0 } }
        for k in particles.indices {
            if particles[k].text == "•" { particles[k].vy -= 0.2; if particles[k].y < 3 { particles[k].life = 0 } }
            particles[k].x += particles[k].vx; particles[k].y += particles[k].vy; particles[k].life -= 1
        }
        particles.removeAll { $0.life <= 0 || $0.x < -10 || $0.x > yard + 10 }
        // battery saver: full 24 fps only while something moves; ~8 fps when resting (breathing + tail)
        if moving || tickN % 3 == 0 { needsDisplay = true }   // 12 fps moving, 4 fps resting
    }

    private func startAct(_ a: Pet.Act?) {
        front = (a == .pat || a == .med || a == .greet || a == .mail || a == .dress)
        if a == .play {
            ballX = min(max(x + (dir > 0 ? dogW + 16 : -16), 8), yard - 12)
            ballY = 12; ballVY = 2; ballVX = dir > 0 ? 1.3 : -1.3
        }
    }

    private func spawn(_ x0: CGFloat, _ y0: CGFloat, _ s: String, _ size: CGFloat, vy: CGFloat, vx: CGFloat = 0) {
        particles.append(Particle(x: x0, y: y0, vx: vx * 1.6, vy: vy * 1.6, life: 20, text: s, size: size))
    }

    // MARK: drawing

    override func drawContent(_ r: NSRect) {
        let kind = pet.reaction?.kind
        let asleep = pet.asleep && kind == nil
        let sick = pet.sick && kind == nil
        let walking = kind == nil && !asleep && !sick && Date() >= pauseUntil
        let running = kind == .play || kind == .zoom

        // props behind the dog
        if kind == .feed { bowlX = dir > 0 ? x + dogW - 3 : x - 9 }
        bowlA += ((kind == .feed ? 1 : 0) - bowlA) * 0.25
        if bowlA > 0.03, let g = NSGraphicsContext.current?.cgContext {
            g.saveGState(); defer { g.restoreGState() }
            g.setAlpha(min(1, bowlA))
            let bx = r.minX + bowlX
            NSColor(srgbRed: 0.86, green: 0.26, blue: 0.28, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: bx, y: r.minY + 2.5, width: 12, height: 4.5), xRadius: 2.2, yRadius: 2.2).fill()
            NSColor(srgbRed: 1.0, green: 0.55, blue: 0.55, alpha: 1).setFill()                   // rim highlight
            NSRect(x: bx + 1, y: r.minY + 6.2, width: 10, height: 0.8).fill()
            NSColor(srgbRed: 0.55, green: 0.33, blue: 0.16, alpha: 1).setFill()      // kibble mound
            for (dx, dy) in [(2.5, 5.6), (4.6, 6.3), (6.8, 6.0), (8.6, 5.5), (5.6, 7.2)] as [(CGFloat, CGFloat)] {
                NSBezierPath(ovalIn: NSRect(x: bx + dx, y: r.minY + dy, width: 2.0, height: 1.7)).fill()
            }
        }

        for (i, px) in poopXs.enumerated() {
            let bx = r.minX + px
            let brown = NSColor(srgbRed: 0.40, green: 0.24, blue: 0.10, alpha: 1)
            brown.setFill()
            NSBezierPath(ovalIn: NSRect(x: bx, y: r.minY + 2.5, width: 7, height: 3)).fill()
            NSBezierPath(ovalIn: NSRect(x: bx + 1.2, y: r.minY + 4.6, width: 4.6, height: 2.6)).fill()
            NSBezierPath(ovalIn: NSRect(x: bx + 2.4, y: r.minY + 6.4, width: 2.4, height: 2.0)).fill()
            let stink = NSBezierPath()                                    // wavy stink lines
            for k in 0..<2 {
                let sx = bx + 2 + CGFloat(k) * 3, w = CGFloat(sin(t * 3 + Double(i + k)))
                stink.move(to: NSPoint(x: sx, y: r.minY + 9)); stink.curve(to: NSPoint(x: sx + w, y: r.minY + 14),
                    controlPoint1: NSPoint(x: sx + 1.5, y: r.minY + 10.5), controlPoint2: NSPoint(x: sx - 1.5, y: r.minY + 12.5))
            }
            stink.lineWidth = 0.6; NSColor(srgbRed: 0.6, green: 0.75, blue: 0.4, alpha: 0.8).setStroke(); stink.stroke()
        }

        // pose parameters (dog local space: facing right, origin at its left foot line)
        let ph = phase
        let swing: CGFloat = walking || running ? CGFloat(sin(ph)) * (running ? 0.75 : 0.5) : 0
        var legH: CGFloat = 5.2
        var bodyBob: CGFloat = walking || running ? CGFloat(abs(sin(ph))) * 0.8 : 0
        var headDX: CGFloat = 0, headDY: CGFloat = 0
        var osc: CGFloat = walking ? CGFloat(sin(ph * 2)) * 0.45 : 0      // fast bobbing, added after smoothing
        var tailUp: CGFloat = 0.7, wagSpeed = 7.0, wagAmp: CGFloat = 0.35
        var eyesClosed = t < blinkUntil, happyEyes = false, tongue = false
        var shiver: CGFloat = 0
        let breathe = CGFloat(sin(t * 1.8)) * 0.35

        switch kind {
        case .feed?:
            headDX = 3.4; headDY = -8.4; osc = CGFloat(sin(t * 11)) * 0.8      // head down in the bowl, chewing
            tailUp = 0.9; wagSpeed = 12; wagAmp = 0.45
        case .pat?:
            let press = max(0, CGFloat(sin(t * 6)))
            osc = -1.3 * press; happyEyes = true; tongue = true
            tailUp = 1.0; wagSpeed = 16; wagAmp = 0.55; bodyBob = press * 0.3
        case .play?:
            tongue = true; tailUp = 1.0; wagSpeed = 14; wagAmp = 0.5
        case .med?:
            tailUp = 0.3; wagSpeed = 3; headDY = -1
        case .bath?:
            shiver = (tickN % 2 == 0) ? 0.7 : -0.7; eyesClosed = true; tailUp = 0.2   // shake shake
        case .clean?, .dress?:
            happyEyes = pet.reaction?.kind == .dress; tailUp = 1.0; wagSpeed = 12; wagAmp = 0.5
        case .zoom?, .greet?, .celebrate?:
            tongue = true; happyEyes = kind != .zoom; tailUp = 1.1; wagSpeed = 18; wagAmp = 0.6
        case .mail?:
            tailUp = 1.0; wagSpeed = 14; wagAmp = 0.5
        case nil:
            if asleep {
                legH = 1.2; headDX = 1.0; headDY = -4.2 + breathe * 0.6; eyesClosed = true
                tailUp = -0.5; wagSpeed = 0.8; wagAmp = 0.06; bodyBob = breathe
            } else if sick {
                headDY = -2.2; tailUp = -0.9; wagSpeed = 1.2; wagAmp = 0.08
                shiver = (tickN % 4 < 2) ? 0.4 : -0.4
            } else if !walking {
                tailUp = pet.fun < 35 ? -0.2 : 0.7; wagSpeed = pet.fun < 35 ? 2 : 6
                headDY = CGFloat(sin(t * 0.9)) * 0.4 + breathe * 0.4   // looking around, breathing
            } else if pet.fun < 35 { tailUp = -0.1; wagSpeed = 2.5 }
            if pet.cpuHot && !asleep { tongue = true }                       // panting
            if pet.batteryLow && !asleep { wagSpeed = min(wagSpeed, 2); if Int(t * 2) % 5 == 0 { eyesClosed = true } }
        }
        if asleep && !wasAsleep { yawnUntil = t + 1.8 }                       // big yawn, then lie down
        if !asleep && wasAsleep && kind == nil { stretchUntil = t + 1.8 }    // wake-up stretch
        wasAsleep = asleep
        let yawning = t < yawnUntil
        if yawning { legH = 5.2; headDY = 0.3; headDX = 0; eyesClosed = true; tongue = true; wagSpeed = 1; wagAmp = 0.1 }
        if t < stretchUntil {                                                // play-bow stretch: chest down, tail up
            headDX = 2.0; headDY = -3.2; tailUp = 1.2; eyesClosed = true; legH = 5.2
        }

        // ease every pose change (eat → sleep, walk → sit, side → front) instead of snapping
        let k: CGFloat = 0.2
        let tLeg = legH, tHX = headDX, tHY = headDY, tTail = tailUp
        sLegH += (tLeg - sLegH) * k; sHX += (tHX - sHX) * k; sHY += (tHY - sHY) * k
        sTail += (tTail - sTail) * k; sWagAmp += (wagAmp - sWagAmp) * k; sWagSpeed += (wagSpeed - sWagSpeed) * 0.2
        let turnT: CGFloat = (front && !asleep && !yawning) ? 1 : 0
        turnS += (turnT - turnS) * 0.3
        dirS += (dir - dirS) * 0.35
        ballA += ((kind == .play ? 1 : 0) - ballA) * 0.3
        settling = abs(tLeg - sLegH) > 0.05 || abs(tHY - sHY) > 0.05 || abs(tHX - sHX) > 0.05 || abs(tTail - sTail) > 0.03
            || abs(turnT - turnS) > 0.02 || abs(dir - dirS) > 0.02 || (bowlA > 0.03 && kind != .feed) || (ballA > 0.03 && kind != .play)
        legH = sLegH; headDX = sHX; headDY = sHY + osc; tailUp = sTail; wagAmp = sWagAmp
        if asleep && sLegH > 2.6 { eyesClosed = true }                      // eyes shut as she settles down

        // ears lag behind head motion (springy flop)
        let headY = headDY + bodyBob
        earLag += ((lastHeadY - headY) * 1.6 - earLag) * 0.35
        lastHeadY = headY

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let ox = (r.minX + x + shiver).rounded(.toNearestOrAwayFromZero)
        let oy = r.minY + 3 + min(jumpY, front ? 1.6 : 1.8)          // never jump out of the chip
        ctx.translateBy(x: ox + dogW / 2, y: oy)
        let flip = abs(dirS) < 0.12 ? (dirS < 0 ? -0.12 : 0.12) : dirS          // turning around squashes through the middle
        let squeeze = max(0.12, abs(1 - 2 * turnS))                          // turning to face you does the same
        ctx.scaleBy(x: flip * squeeze, y: 1)
        ctx.translateBy(x: -dogW / 2, y: 0)

        let fur = pet.sick ? FUR_SICK : FUR
        let hi = pet.sick ? FUR_SICK.blended(withFraction: 0.2, of: .white)! : FUR_HI
        let blush = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.60, alpha: 0.55)
        /// curly coat: a cluster of overlapping puffs with small highlight curls
        func fluff(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor, seed: Int, shine: Bool = true) {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)).fill()
            let n = max(6, Int((w + h) / 2.0))
            for k in 0..<n {
                let a = Double(k) / Double(n) * 2 * .pi + Double(seed)
                let px = cx + CGFloat(cos(a)) * w * 0.44, py = cy + CGFloat(sin(a)) * h * 0.44
                let rr: CGFloat = 1.5 + CGFloat((k * 7 + seed) % 3) * 0.35
                NSBezierPath(ovalIn: NSRect(x: px - rr, y: py - rr, width: rr * 2, height: rr * 2)).fill()
            }
            guard shine else { return }
            hi.setFill()
            for k in 0..<max(2, n / 3) {
                let a = Double(k) * 2.4 + Double(seed) * 0.7
                let px = cx + CGFloat(cos(a)) * w * 0.22, py = cy + CGFloat(sin(a)) * h * 0.2 + h * 0.14
                NSBezierPath(ovalIn: NSRect(x: px - 0.75, y: py - 0.6, width: 1.5, height: 1.2)).fill()
            }
        }
        func eye(_ ex: CGFloat, _ ey: CGFloat) {
            if happyEyes || eyesClosed {
                let e = NSBezierPath()
                if happyEyes { e.move(to: NSPoint(x: ex - 1.2, y: ey - 0.3)); e.line(to: NSPoint(x: ex, y: ey + 0.8)); e.line(to: NSPoint(x: ex + 1.2, y: ey - 0.3)) }
                else { e.move(to: NSPoint(x: ex - 1.2, y: ey)); e.curve(to: NSPoint(x: ex + 1.2, y: ey), controlPoint1: NSPoint(x: ex - 0.4, y: ey - 0.7), controlPoint2: NSPoint(x: ex + 0.4, y: ey - 0.7)) }
                e.lineWidth = 0.95; e.lineCapStyle = .round; INK.setStroke(); e.stroke()
            } else {   // big shiny eye
                INK.setFill(); NSBezierPath(ovalIn: NSRect(x: ex - 1.25, y: ey - 1.3, width: 2.5, height: 2.8)).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: ex - 0.1, y: ey + 0.35, width: 0.95, height: 0.95)).fill()
                NSBezierPath(ovalIn: NSRect(x: ex - 0.75, y: ey - 0.8, width: 0.45, height: 0.45)).fill()
            }
        }
        func curlyEar(_ root: NSPoint, _ angle: CGFloat, _ mirror: Bool) {
            ctx.saveGState()
            ctx.translateBy(x: root.x, y: root.y)
            ctx.rotate(by: angle)
            for k in 0..<4 {
                let cy = -CGFloat(k) * 2.0, w: CGFloat = 4.6 - CGFloat(k) * 0.3
                let dx: CGFloat = (k % 2 == 0 ? 0 : 0.45) * (mirror ? -1 : 1)
                FUR_DARK.setFill(); NSBezierPath(ovalIn: NSRect(x: -w / 2 + dx, y: cy - 1.7, width: w, height: 3.4)).fill()
            }
            ctx.restoreGState()
        }
        let tilt = CGFloat(sin(t * 0.7)) * 0.12            // gentle curious head tilt
        let outfit = pet.outfit
        /// accessories, drawn in head space; `topY` = topknot centre, `eye` = eye position(s)
        func headwear(topX: CGFloat, topY: CGFloat, eyes: [NSPoint]) {
            switch outfit {
            case "bow":
                NSColor(srgbRed: 1.0, green: 0.42, blue: 0.62, alpha: 1).setFill()
                let bx = topX + 3.2, by = topY + 1.2
                let l = NSBezierPath(); l.move(to: NSPoint(x: bx, y: by)); l.line(to: NSPoint(x: bx - 3, y: by + 1.8)); l.line(to: NSPoint(x: bx - 3, y: by - 1.8)); l.close(); l.fill()
                let rr = NSBezierPath(); rr.move(to: NSPoint(x: bx, y: by)); rr.line(to: NSPoint(x: bx + 3, y: by + 1.8)); rr.line(to: NSPoint(x: bx + 3, y: by - 1.8)); rr.close(); rr.fill()
                NSColor(srgbRed: 0.85, green: 0.25, blue: 0.45, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: bx - 1, y: by - 1, width: 2, height: 2)).fill()
            case "crown":
                NSColor(srgbRed: 1.0, green: 0.80, blue: 0.20, alpha: 1).setFill()
                let c = NSBezierPath(); let cx = topX, cy = topY + 1.8
                c.move(to: NSPoint(x: cx - 3.6, y: cy)); c.line(to: NSPoint(x: cx - 3.6, y: cy + 3)); c.line(to: NSPoint(x: cx - 1.8, y: cy + 1.4))
                c.line(to: NSPoint(x: cx, y: cy + 3.6)); c.line(to: NSPoint(x: cx + 1.8, y: cy + 1.4)); c.line(to: NSPoint(x: cx + 3.6, y: cy + 3))
                c.line(to: NSPoint(x: cx + 3.6, y: cy)); c.close(); c.fill()
            case "santa":
                NSColor(srgbRed: 0.88, green: 0.15, blue: 0.18, alpha: 1).setFill()
                let h = NSBezierPath(); h.move(to: NSPoint(x: topX - 4, y: topY)); h.line(to: NSPoint(x: topX + 4, y: topY))
                h.line(to: NSPoint(x: topX + 5.5, y: topY + 5.5)); h.close(); h.fill()
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: topX - 4.6, y: topY - 1, width: 9.2, height: 2), xRadius: 1, yRadius: 1).fill()
                NSBezierPath(ovalIn: NSRect(x: topX + 4.6, y: topY + 4.6, width: 2.2, height: 2.2)).fill()
            case "glasses":
                for e in eyes {
                    INK.setFill(); NSBezierPath(roundedRect: NSRect(x: e.x - 2.0, y: e.y - 1.4, width: 4.0, height: 2.8), xRadius: 1, yRadius: 1).fill()
                    NSColor(white: 1, alpha: 0.5).setFill(); NSRect(x: e.x - 1.3, y: e.y + 0.3, width: 1.2, height: 0.6).fill()
                }
                if eyes.count == 2 { INK.setStroke(); let b = NSBezierPath(); b.move(to: NSPoint(x: eyes[0].x + 2, y: eyes[0].y + 0.4)); b.line(to: NSPoint(x: eyes[1].x - 2, y: eyes[1].y + 0.4)); b.lineWidth = 0.7; b.stroke() }
            default: break
            }
        }
        func dirtSpots(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            guard pet.dirt >= 50 else { return }
            NSColor(srgbRed: 0.30, green: 0.22, blue: 0.16, alpha: 0.75).setFill()
            for (dx, dy) in [(-0.3, 0.1), (0.15, -0.2), (0.3, 0.2), (-0.1, -0.25)] as [(CGFloat, CGFloat)] {
                NSBezierPath(ovalIn: NSRect(x: cx + dx * w - 0.9, y: cy + dy * h - 0.6, width: 1.8, height: 1.2)).fill()
            }
        }

        if turnS > 0.5 {
            // ---- facing you ----
            let cx: CGFloat = dogW / 2, by = 0.2 + bodyBob * 0.4
            fluff(cx, by + 6.2 + breathe * 0.4, 14.5, 9.0, fur, seed: 1)     // fluffy chest
            dirtSpots(cx, by + 6, 14, 8)
            if outfit == "scarf" {
                NSColor(srgbRed: 0.85, green: 0.22, blue: 0.25, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: cx - 6, y: by + 9.2, width: 12, height: 2.6), xRadius: 1.3, yRadius: 1.3).fill()
                NSBezierPath(roundedRect: NSRect(x: cx + 2.2, y: by + 5.4, width: 2.4, height: 4.4), xRadius: 1, yRadius: 1).fill()
            }
            fluff(cx - 3.9, by + 1.9, 4.8, 3.6, hi, seed: 2)                 // front paws (lighter, so they read)
            fluff(cx + 3.9, by + 1.9, 4.8, 3.6, hi, seed: 4)
            ctx.saveGState()
            ctx.translateBy(x: cx, y: by + 13.2 + headDY * 0.5)
            ctx.rotate(by: kind == .pat ? CGFloat(sin(t * 6)) * 0.08 : tilt)
            curlyEar(NSPoint(x: -5.2, y: 1.6), 0.18 - earLag * 0.2, true)
            curlyEar(NSPoint(x: 5.2, y: 1.6), -0.18 + earLag * 0.2, false)
            fluff(0, 0.6, 12.2, 10.6, fur, seed: 5)                           // head
            fluff(0, 6.2, 7.8, 5.0, hi, seed: 9)                              // topknot (lighter pom)
            blush.setFill()
            NSBezierPath(ovalIn: NSRect(x: -5.6, y: -2.6, width: 2.6, height: 1.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 3.0, y: -2.6, width: 2.6, height: 1.5)).fill()
            eye(-2.6, 1.0); eye(2.6, 1.0)
            headwear(topX: 0, topY: 6.4, eyes: [NSPoint(x: -2.6, y: 1.0), NSPoint(x: 2.6, y: 1.0)])
            CREAM.setFill(); NSBezierPath(roundedRect: NSRect(x: -2.6, y: -3.9, width: 5.2, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
            INK.setFill(); NSBezierPath(ovalIn: NSRect(x: -1.0, y: -1.5, width: 2.0, height: 1.5)).fill()
            if tongue {
                NSColor(srgbRed: 0.98, green: 0.47, blue: 0.56, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: -0.9, y: -5.4 + CGFloat(sin(t * 9)) * 0.3, width: 1.9, height: 2.3)).fill()
            }
            if kind == .mail {                                             // letter in her mouth
                NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: -3.2, y: -7.2, width: 6.4, height: 4.2)).fill()
                let v = NSBezierPath(); v.move(to: NSPoint(x: -3.2, y: -3.0)); v.line(to: NSPoint(x: 0, y: -5.3)); v.line(to: NSPoint(x: 3.2, y: -3.0))
                v.lineWidth = 0.6; NSColor(white: 0.5, alpha: 1).setStroke(); v.stroke()
            }
            ctx.restoreGState()
        } else {
            // ---- side view (chibi: big head, short fluffy legs) ----
            let bodyY = 1.0 + max(0, min(1, (legH - 1.2) / 4.0)) * 2.6 + bodyBob   // sinks smoothly when lying down
            func leg(_ hipX: CGFloat, _ angle: CGFloat, _ color: NSColor, seed: Int) {
                if legH < 2 { fluff(hipX, 1.6, 4.0, 2.6, color, seed: seed, shine: false); return }   // lying: paws
                let fx = hipX + sin(angle) * 3.4, fy: CGFloat = 1.9
                let p = NSBezierPath(); p.move(to: NSPoint(x: hipX, y: bodyY + 1.2)); p.line(to: NSPoint(x: fx, y: fy))
                p.lineWidth = 3.8; p.lineCapStyle = .round; color.setStroke(); p.stroke()       // full fur leg
                fluff((hipX + fx) / 2, (bodyY + fy) / 2 + 0.4, 3.6, 3.2, color, seed: seed, shine: false)
                fluff(fx, fy, 4.4, 3.2, color, seed: seed + 1, shine: false)                    // fluffy paw
            }
            let farC = fur.blended(withFraction: 0.28, of: .black) ?? fur
            leg(7.5, swing * 0.7, farC, seed: 11)
            leg(16.5, -swing * 0.7, farC, seed: 13)
            let wag = CGFloat(sin(wagPhase)) * wagAmp
            let tb = NSPoint(x: 5, y: bodyY + 5.2), ang = tailUp + wag
            let tip = NSPoint(x: tb.x - 3.2 * cos(ang), y: tb.y + 3.8 * sin(ang))
            let tp = NSBezierPath(); tp.move(to: tb); tp.line(to: tip); tp.lineWidth = 2.2; tp.lineCapStyle = .round
            fur.setStroke(); tp.stroke()
            fluff(tip.x, tip.y, 4.6, 4.6, fur, seed: 3)                                      // pom-pom tail
            fluff(11.5, bodyY + 4.2 + (legH < 2 ? breathe * 0.5 : 0), 15.5, 8.6, fur, seed: 1) // round fluffy body
            dirtSpots(11.5, bodyY + 4.2, 15, 8)
            if outfit == "scarf" {
                NSColor(srgbRed: 0.85, green: 0.22, blue: 0.25, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 15.6, y: bodyY + 5.0, width: 3.2, height: 6.2), xRadius: 1.4, yRadius: 1.4).fill()
            }
            let nearC = fur.blended(withFraction: 0.12, of: .white) ?? fur
            leg(6.5, -swing * 0.7, nearC, seed: 17)
            leg(15.5, swing * 0.7, nearC, seed: 19)
            let hc = NSPoint(x: 20.5 + headDX, y: bodyY + 10.4 + headDY)
            ctx.saveGState()
            ctx.translateBy(x: hc.x, y: hc.y)
            ctx.rotate(by: walking ? 0 : tilt * 0.6)
            fluff(0, 0, 11.4, 10.4, fur, seed: 5)                                             // big round head
            fluff(-0.8, 5.2, 7.4, 4.8, hi, seed: 9)                                           // topknot (lighter pom)
            blush.setFill(); NSBezierPath(ovalIn: NSRect(x: 0.8, y: -2.6, width: 2.6, height: 1.5)).fill()
            CREAM.setFill(); NSBezierPath(roundedRect: NSRect(x: 2.4, y: -3.4, width: 5.0, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
            INK.setFill(); NSBezierPath(ovalIn: NSRect(x: 6.0, y: -1.8, width: 1.9, height: 1.6)).fill()
            if tongue {
                NSColor(srgbRed: 0.98, green: 0.47, blue: 0.56, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 3.9, y: -4.9 + CGFloat(sin(t * 9)) * 0.3, width: 2.1, height: 2.5)).fill()
            }
            eye(2.2, 1.2)
            headwear(topX: -0.8, topY: 5.4, eyes: [NSPoint(x: 2.2, y: 1.2)])
            curlyEar(NSPoint(x: -2.4, y: 2.6), -0.22 + earLag * 0.3 + (asleep ? 0.35 : 0), false)
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // ball, hand, particles (screen space)
        if ballA > 0.03 {
            if kind != .play { ballY = max(2.5, ballY - 1.5) }               // drops and fades out
            NSColor(srgbRed: 0.80, green: 0.95, blue: 0.22, alpha: min(1, ballA)).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + ballX, y: r.minY + ballY, width: 5, height: 5)).fill()
        }
        for p in particles {
            if p.life < 5 { continue }                                   // vanish cleanly (no dark smudge)
            let alpha: CGFloat = 1
            let c: NSColor
            switch p.text {
            case "♥": c = .systemPink
            case "+": c = workingGreen
            case "z": c = NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 1)
            case "○", "●": c = NSColor(srgbRed: 0.70, green: 0.88, blue: 1, alpha: 1)
            case "✦": c = [NSColor.systemYellow, .systemPink, toolTeal, .systemOrange][((Int(p.y * 7) % 4) + 4) % 4]
            default: c = NSColor(srgbRed: 0.65, green: 0.45, blue: 0.25, alpha: 1)
            }
            let a = NSAttributedString(string: p.text, attributes: [.font: NSFont.systemFont(ofSize: p.size, weight: .bold),
                                                                    .foregroundColor: c.withAlphaComponent(alpha)])
            a.draw(at: NSPoint(x: r.minX + p.x, y: r.minY + p.y))
        }
        if pet.cpuHot && !pet.asleep {                                   // sweating
            let sx = r.minX + x + (front ? dogW / 2 + 6 : (dir > 0 ? dogW - 8 : 8)), sy = r.minY + 19 - CGFloat((tickN / 2) % 6)
            NSColor(srgbRed: 0.45, green: 0.75, blue: 1.0, alpha: 0.9).setFill()
            let d = NSBezierPath(); d.move(to: NSPoint(x: sx, y: sy + 2.6))
            d.curve(to: NSPoint(x: sx, y: sy), controlPoint1: NSPoint(x: sx - 1.6, y: sy + 0.6), controlPoint2: NSPoint(x: sx - 1.2, y: sy))
            d.curve(to: NSPoint(x: sx, y: sy + 2.6), controlPoint1: NSPoint(x: sx + 1.2, y: sy), controlPoint2: NSPoint(x: sx + 1.6, y: sy + 0.6))
            d.fill()
        }
        // words: what she's saying (events) beats what she needs
        let words: String? = pet.saying?.text ?? ((kind == nil && !pet.asleep && Int(t / 1.2) % 3 != 0) ? pet.need : nil)
        if let n = words {
            let a = NSAttributedString(string: n, attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
                                                               .foregroundColor: NSColor(white: 0.92, alpha: 1)])
            let bx = dir > 0 ? r.minX + x + dogW - 2 : r.minX + x - a.size().width + 2
            a.draw(at: NSPoint(x: max(r.minX + 1, min(bx, r.maxX - a.size().width - 1)), y: r.maxY - a.size().height + 1))
        }
    }
}

// MARK: - pet row (after tapping the dog)

final class PetStatusChip: Chip {
    private let pet = Pet.shared
    override init() { super.init(); setWidth(190) }
    required init?(coder: NSCoder) { fatalError() }

    override func drawContent(_ r: NSRect) {
        pet.update()
        let top = attr("\(pet.name) · \(pet.moodWord)", 11, .semibold, pet.sick ? .systemOrange : .white)
        top.draw(at: NSPoint(x: r.minX + 8, y: r.maxY - top.size().height - 1))
        // bond level + streak, right side of the top line
        let lv = attr("Lv\(pet.level)" + (pet.streak > 1 ? " 🔥\(pet.streak)" : ""), 9, .bold, .systemPink)
        lv.draw(at: NSPoint(x: r.maxX - lv.size().width - 8, y: r.maxY - lv.size().height - 1.5))
        let lt = NSRect(x: r.maxX - lv.size().width - 8, y: r.maxY - 14.5, width: lv.size().width, height: 1.6)
        trackColor.setFill(); NSBezierPath(roundedRect: lt, xRadius: 0.8, yRadius: 0.8).fill()
        NSColor.systemPink.setFill()
        NSBezierPath(roundedRect: NSRect(x: lt.minX, y: lt.minY, width: max(1.6, lt.width * CGFloat(pet.nextLevelProgress)), height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
        // four mini bars: food, fun, health, clean
        let bars: [(String, Double, NSColor)] = [("🍖", pet.hunger, .systemOrange), ("🎾", pet.fun, toolTeal),
                                                  ("❤️", pet.health, pet.sick ? .systemRed : workingGreen),
                                                  ("🫧", 100 - pet.dirt, NSColor(srgbRed: 0.55, green: 0.8, blue: 1, alpha: 1))]
        var bx = r.minX + 8
        for (icon, v, c) in bars {
            let ia = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: 7)])
            ia.draw(at: NSPoint(x: bx, y: r.minY + 2))
            let track = NSRect(x: bx + 10, y: r.minY + 4.5, width: 32, height: 4)
            trackColor.setFill(); NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            c.setFill(); NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: max(2, track.width * CGFloat(v / 100)), height: 4), xRadius: 2, yRadius: 2).fill()
            bx += 45
        }
    }
}

final class PetActionChip: Chip {
    private let icon: String, label: String
    init(_ icon: String, _ label: String) {
        self.icon = icon; self.label = label
        super.init()
        setWidth(attr(label, 11, .semibold).size().width + 38)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func drawContent(_ r: NSRect) {
        let i = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        i.draw(at: NSPoint(x: r.minX + 7, y: r.midY - i.size().height / 2))
        let t = attr(label, 11, .semibold)
        t.draw(at: NSPoint(x: r.minX + 29, y: r.midY - t.size().height / 2))
    }
}
