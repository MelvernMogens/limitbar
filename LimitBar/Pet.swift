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
    private var last: Date

    enum Act { case feed, play, pat, med }
    /// short-lived reaction after you do something (an animation in the yard)
    var reaction: (kind: Act, icon: String, until: Date)?

    private init() {
        hunger = d.object(forKey: "pet.hunger") as? Double ?? 80
        fun = d.object(forKey: "pet.fun") as? Double ?? 80
        health = d.object(forKey: "pet.health") as? Double ?? 100
        sick = d.bool(forKey: "pet.sick")
        last = Date(timeIntervalSince1970: d.double(forKey: "pet.last"))
        if d.double(forKey: "pet.last") == 0 { last = Date() }
        update()
    }

    private func save() {
        d.set(hunger, forKey: "pet.hunger"); d.set(fun, forKey: "pet.fun")
        d.set(health, forKey: "pet.health"); d.set(sick, forKey: "pet.sick")
    }

    var asleep: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return (h >= 23 || h < 7) && reaction == nil
    }

    /// Needs change slowly over real time (also while LimitBar was closed).
    func update() {
        let now = Date()
        let hours = min(now.timeIntervalSince(last) / 3600, 48)   // cap: a long trip away doesn't wreck it
        last = now
        d.set(now.timeIntervalSince1970, forKey: "pet.last")
        guard hours > 0 else { return }
        let rate = asleep ? 0.4 : 1.0
        hunger = max(0, hunger - 6 * hours * rate)
        fun = max(0, fun - 5 * hours * rate)
        if hunger < 20 || fun < 15 {
            health = max(0, health - 5 * hours)          // neglect wears it down
        } else if !sick {
            health = min(100, health + 4 * hours)
        }
        if !sick && health < 40 { sick = true }
        if let r = reaction, r.until < now { reaction = nil }
    }

    /// What it wants right now (shown in a bubble), most urgent first.
    var need: String? {
        if sick { return "🤒 sick…" }
        if hunger < 35 { return "🍖 hungry!" }
        if fun < 35 { return "🎾 play?" }
        if fun < 50 && hunger < 50 { return "😢 sad" }
        return nil
    }

    var moodWord: String {
        if sick { return "sick" }
        if asleep { return "sleeping" }
        if hunger < 35 { return "hungry" }
        if fun < 35 { return "bored" }
        if fun > 75 && hunger > 60 { return "happy" }
        return "ok"
    }

    func feed() { hunger = min(100, hunger + 40); fun = min(100, fun + 3); react(.feed, "🍖", 4.5) }
    func play() { fun = min(100, fun + 35); hunger = max(0, hunger - 5); react(.play, "🎾", 6) }
    func pat() { fun = min(100, fun + 12); react(.pat, "💕", 4) }
    func medicine() {
        health = min(100, health + 45)
        if health >= 50 { sick = false }
        react(.med, "💊", 3)
    }
    private func react(_ k: Act, _ icon: String, _ secs: Double) { reaction = (k, icon, Date().addingTimeInterval(secs)) }
}

// MARK: - pixel art (facing right). . = empty, b = fur, d = ears/patches, w = muzzle/belly, k = eye/nose, p = tongue, z = paws

private let SPR_W = 16
private let walkA = [
    "...........dd...",
    "..........dbbd..",
    "..........bbkbb.",
    ".t........bbbwwk",
    ".tt.......bbbww.",
    "..tbbbbbbbbbbb..",
    "...bbdbbbbbbbb..",
    "...bwwwwwwwbbb..",
    "...bb.bb..bb.bb.",
    "...bb.bb..bb.bb.",
    "...zz.zz..zz.zz.",
]
private let walkB = [
    "...........dd...",
    "..........dbbd..",
    "..........bbkbb.",
    "t.........bbbwwk",
    ".tt.......bbbww.",
    "..tbbbbbbbbbbb..",
    "...bbdbbbbbbbb..",
    "...bwwwwwwwbbb..",
    "..bb..bb.bb..bb.",
    "..bb..bb.bb..bb.",
    "..zz..zz.zz..zz.",
]
private let sitF = [
    "...........dd...",
    "..........dbbd..",
    "..........bbkbb.",
    "..........bbbwwk",
    "..........bbbww.",
    "......bbbbbbbb..",
    ".tt..bbdbbbbbb..",
    "..t.bbbbbbwwb...",
    "...bbbbbbbwwb...",
    "...bbbbbbb.bb...",
    "...zzzzz...zz...",
]
private let happyF = [
    "...........dd...",
    "..........dbbd..",
    "..........bbkbb.",
    "tt........bbbwwk",
    ".tt.......bbbwp.",
    "..tbbbbbbbbbbbp.",
    "...bbdbbbbbbbb..",
    "...bwwwwwwwbbb..",
    "...bb.bb..bb.bb.",
    "...bb.bb..bb.bb.",
    "...zz.zz..zz.zz.",
]
private let eatA = [
    "................",
    "................",
    "...........dd...",
    "..........dbbd..",
    ".t........bbkbb.",
    ".tt.......bbbbb.",
    "..tbbbbbbbbbbwwk",
    "...bbdbbbbbbbww.",
    "...bwwwwwwwbbb..",
    "...bb.bb..bb.bb.",
    "...zz.zz..zz.zz.",
]
private let eatB = [
    "................",
    "................",
    "................",
    "...........dd...",
    "t.........dbbd..",
    ".tt.......bbkbb.",
    "..tbbbbbbbbbbbb.",
    "...bbdbbbbbbbwwk",
    "...bwwwwwwwbbww.",
    "...bb.bb..bb.bb.",
    "...zz.zz..zz.zz.",
]
private let sleepF = [
    "................",
    "................",
    "................",
    "................",
    "................",
    "..........dd....",
    "...bbbbbbdbbd...",
    ".tbbbdbbbbb-bb..",
    "ttbbbbbbbbbbbwwk",
    ".bwwwwwwwwwbbww.",
    ".zz.zz....zz.zz.",
]

private func color(_ c: Character, sick: Bool) -> NSColor? {
    let fur = sick ? NSColor(srgbRed: 0.78, green: 0.80, blue: 0.58, alpha: 1) : NSColor(srgbRed: 0.91, green: 0.72, blue: 0.48, alpha: 1)
    switch c {
    case "b", "t": return fur
    case "d": return NSColor(srgbRed: 0.55, green: 0.35, blue: 0.20, alpha: 1)
    case "w": return NSColor(srgbRed: 1.0, green: 0.95, blue: 0.86, alpha: 1)
    case "k", "-": return NSColor(white: 0.08, alpha: 1)
    case "p": return NSColor(srgbRed: 0.98, green: 0.45, blue: 0.55, alpha: 1)
    case "z": return NSColor(srgbRed: 0.45, green: 0.28, blue: 0.16, alpha: 1)
    default: return nil
    }
}

private func drawSprite(_ rows: [String], at origin: NSPoint, px: CGFloat, flip: Bool, sick: Bool) {
    for (ry, row) in rows.enumerated() {
        for (rx, ch) in row.enumerated() {
            guard let c = color(ch, sick: sick) else { continue }
            c.setFill()
            let x = flip ? CGFloat(SPR_W - 1 - rx) : CGFloat(rx)
            // rows are top-down; AppKit y goes up
            NSRect(x: origin.x + x * px, y: origin.y + CGFloat(rows.count - 1 - ry) * px, width: px, height: px).fill()
        }
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
    private var chaseV: CGFloat = 0              // turned toward you (idle moments, being petted)

    override init() {
        super.init()
        setWidth(yard)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in self?.step() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var moving: Bool {
        pet.reaction != nil || (!(pet.asleep || pet.sick) && Date() >= pauseUntil) || !particles.isEmpty || jumpY > 0
    }

    private func step() {
        tickN += 1
        let dt = 1.0 / 12.0
        t += dt
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
        case nil:
            if !(pet.asleep || pet.sick) && Date() >= pauseUntil {
                let speed: CGFloat = pet.fun < 35 ? 0.37 : 0.75        // points per frame (12 fps)
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
        if jumpV != 0 || jumpY > 0 { jumpY += jumpV; jumpV -= 0.8; if jumpY <= 0 { jumpY = 0; jumpV = 0 } }
        for k in particles.indices {
            if particles[k].text == "•" { particles[k].vy -= 0.2; if particles[k].y < 3 { particles[k].life = 0 } }
            particles[k].x += particles[k].vx; particles[k].y += particles[k].vy; particles[k].life -= 1
        }
        particles.removeAll { $0.life <= 0 }
        // battery saver: full 24 fps only while something moves; ~8 fps when resting (breathing + tail)
        if moving || tickN % 3 == 0 { needsDisplay = true }   // 12 fps moving, 4 fps resting
    }

    private func startAct(_ a: Pet.Act?) {
        particles.removeAll()
        front = (a == .pat || a == .med)
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
        let running = kind == .play

        // props behind the dog
        if kind == .feed {
            let bx = dir > 0 ? r.minX + x + dogW - 3 : r.minX + x - 9
            NSColor(srgbRed: 0.86, green: 0.26, blue: 0.28, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: bx, y: r.minY + 2.5, width: 12, height: 4.5), xRadius: 2.2, yRadius: 2.2).fill()
            NSColor(srgbRed: 1.0, green: 0.55, blue: 0.55, alpha: 1).setFill()                   // rim highlight
            NSRect(x: bx + 1, y: r.minY + 6.2, width: 10, height: 0.8).fill()
            NSColor(srgbRed: 0.55, green: 0.33, blue: 0.16, alpha: 1).setFill()      // kibble mound
            for (dx, dy) in [(2.5, 5.6), (4.6, 6.3), (6.8, 6.0), (8.6, 5.5), (5.6, 7.2)] as [(CGFloat, CGFloat)] {
                NSBezierPath(ovalIn: NSRect(x: bx + dx, y: r.minY + dy, width: 2.0, height: 1.7)).fill()
            }
        }

        // pose parameters (dog local space: facing right, origin at its left foot line)
        let ph = phase
        let swing: CGFloat = walking || running ? CGFloat(sin(ph)) * (running ? 0.75 : 0.5) : 0
        var legH: CGFloat = 5.2
        var bodyBob: CGFloat = walking || running ? CGFloat(abs(sin(ph))) * 0.8 : 0
        var headDX: CGFloat = 0, headDY: CGFloat = walking ? CGFloat(sin(ph * 2)) * 0.45 : 0
        var tailUp: CGFloat = 0.7, wagSpeed = 7.0, wagAmp: CGFloat = 0.35
        var eyesClosed = t < blinkUntil, happyEyes = false, tongue = false
        var shiver: CGFloat = 0
        let breathe = CGFloat(sin(t * 1.8)) * 0.35

        switch kind {
        case .feed?:
            headDX = 3.4; headDY = -8.4 + CGFloat(sin(t * 11)) * 0.8      // head down in the bowl, chewing
            tailUp = 0.9; wagSpeed = 12; wagAmp = 0.45
        case .pat?:
            let press = max(0, CGFloat(sin(t * 6)))
            headDY = -1.3 * press; happyEyes = true; tongue = true
            tailUp = 1.0; wagSpeed = 16; wagAmp = 0.55; bodyBob = press * 0.3
        case .play?:
            tongue = true; tailUp = 1.0; wagSpeed = 14; wagAmp = 0.5
        case .med?:
            tailUp = 0.3; wagSpeed = 3; headDY = -1
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
        }
        // ears lag behind head motion (springy flop)
        let headY = headDY + bodyBob
        earLag += ((lastHeadY - headY) * 1.6 - earLag) * 0.35
        lastHeadY = headY

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let ox = (r.minX + x + shiver).rounded(.toNearestOrAwayFromZero)
        let oy = r.minY + 3 + jumpY
        ctx.translateBy(x: ox + (dir < 0 ? dogW : 0), y: oy)
        if dir < 0 { ctx.scaleBy(x: -1, y: 1) }

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

        if front && !asleep {
            // ---- facing you ----
            let cx: CGFloat = dogW / 2, by = 0.2 + bodyBob * 0.4
            fluff(cx, by + 6.2 + breathe * 0.4, 14.5, 9.0, fur, seed: 1)     // fluffy chest
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
            CREAM.setFill(); NSBezierPath(roundedRect: NSRect(x: -2.6, y: -3.9, width: 5.2, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
            INK.setFill(); NSBezierPath(ovalIn: NSRect(x: -1.0, y: -1.5, width: 2.0, height: 1.5)).fill()
            if tongue {
                NSColor(srgbRed: 0.98, green: 0.47, blue: 0.56, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: -0.9, y: -5.4 + CGFloat(sin(t * 9)) * 0.3, width: 1.9, height: 2.3)).fill()
            }
            ctx.restoreGState()
        } else {
            // ---- side view (chibi: big head, short fluffy legs) ----
            let bodyY = (legH < 2 ? 1.0 : 3.6) + bodyBob
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
            let wag = CGFloat(sin(t * wagSpeed)) * wagAmp
            let tb = NSPoint(x: 5, y: bodyY + 5.2), ang = tailUp + wag
            let tip = NSPoint(x: tb.x - 3.2 * cos(ang), y: tb.y + 3.8 * sin(ang))
            let tp = NSBezierPath(); tp.move(to: tb); tp.line(to: tip); tp.lineWidth = 2.2; tp.lineCapStyle = .round
            fur.setStroke(); tp.stroke()
            fluff(tip.x, tip.y, 4.6, 4.6, fur, seed: 3)                                      // pom-pom tail
            fluff(11.5, bodyY + 4.2 + (legH < 2 ? breathe * 0.5 : 0), 15.5, 8.6, fur, seed: 1) // round fluffy body
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
            curlyEar(NSPoint(x: -2.4, y: 2.6), -0.22 + earLag * 0.3 + (asleep ? 0.35 : 0), false)
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // ball, hand, particles (screen space)
        if kind == .play {
            NSColor(srgbRed: 0.80, green: 0.95, blue: 0.22, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + ballX, y: r.minY + ballY, width: 5, height: 5)).fill()
        }
        for p in particles {
            if p.life < 5 { continue }                                   // vanish cleanly (no dark smudge)
            let alpha: CGFloat = 1
            let c: NSColor = p.text == "♥" ? .systemPink : (p.text == "+" ? workingGreen : (p.text == "z" ? NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 1) : NSColor(srgbRed: 0.65, green: 0.45, blue: 0.25, alpha: 1)))
            let a = NSAttributedString(string: p.text, attributes: [.font: NSFont.systemFont(ofSize: p.size, weight: .bold),
                                                                    .foregroundColor: c.withAlphaComponent(alpha)])
            a.draw(at: NSPoint(x: r.minX + p.x, y: r.minY + p.y))
        }
        // need bubble when idle
        if kind == nil, !pet.asleep, let n = pet.need, Int(t / 1.2) % 3 != 0 {
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
    override init() { super.init(); setWidth(150) }
    required init?(coder: NSCoder) { fatalError() }

    override func drawContent(_ r: NSRect) {
        pet.update()
        let top = attr("\(pet.name) · \(pet.moodWord)", 11, .semibold, pet.sick ? .systemOrange : .white)
        top.draw(at: NSPoint(x: r.minX + 8, y: r.maxY - top.size().height - 1))
        // three mini bars: food, fun, health
        let bars: [(String, Double, NSColor)] = [("🍖", pet.hunger, .systemOrange), ("🎾", pet.fun, toolTeal),
                                                  ("❤️", pet.health, pet.sick ? .systemRed : workingGreen)]
        var bx = r.minX + 8
        for (icon, v, c) in bars {
            let ia = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: 7)])
            ia.draw(at: NSPoint(x: bx, y: r.minY + 2))
            let track = NSRect(x: bx + 10, y: r.minY + 4.5, width: 30, height: 4)
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
        setWidth(attr(label, 11, .semibold).size().width + 34)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func drawContent(_ r: NSRect) {
        let i = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        i.draw(at: NSPoint(x: r.minX + 7, y: r.midY - i.size().height / 2))
        let t = attr(label, 11, .semibold)
        t.draw(at: NSPoint(x: r.minX + 26, y: r.midY - t.size().height / 2))
    }
}
