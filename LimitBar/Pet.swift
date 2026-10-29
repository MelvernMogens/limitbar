import AppKit
import IOKit.ps

// MARK: - Candie, the Touch Bar toy poodle
// A tiny pixel dog that lives next to the stats chip. It walks around on its own, sleeps at night,
// and asks for things with a little bubble when it needs them. Ignore it and it gets sad, then sick.
// Tap it to Feed / Play / Pet (and Medicine when sick). Drawn in code (no images); ~1 MB, <1% CPU.

final class Pet {
    static let candie = Pet(prefix: "pet.", name: "Candie")
    static let dior = Pet(prefix: "dior.", name: "Dior")
    static var all: [Pet] { [candie, dior] }
    /// the dog the pet row (Feed / Play / Pet…) acts on; tap the status chip to switch
    static var selected: Pet = candie
    static var shared: Pet { selected }
    static var forceAwake = false
    static var forceHot = false            // test hook: pretend the CPU is cooking          // test hook: pretend it's daytime
    let name: String
    private let prefix: String
    private let d = UserDefaults.standard
    private func key(_ k: String) -> String { prefix + k }

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

    enum Act { case feed, play, pat, med, clean, bath, zoom, greet, celebrate, mail, dress, trick, birthday }
    /// short-lived reaction (an animation in the yard) + optional words in a bubble
    var reaction: (kind: Act, icon: String, until: Date)?
    var saying: (text: String, until: Date)?

    // live Mac mood (set from LimitBar's stats every 2 s; not saved)
    var cpuHot = false, ramFull = false, batteryLow = false

    private init(prefix: String, name: String) {
        self.prefix = prefix; self.name = name
        func key(_ k: String) -> String { prefix + k }
        hunger = d.object(forKey: key("hunger")) as? Double ?? 80
        fun = d.object(forKey: key("fun")) as? Double ?? 80
        health = d.object(forKey: key("health")) as? Double ?? 100
        sick = d.bool(forKey: key("sick"))
        dirt = d.object(forKey: key("dirt")) as? Double ?? 10
        poops = d.integer(forKey: key("poops"))
        bond = d.double(forKey: key("bond"))
        streak = d.integer(forKey: key("streak"))
        outfit = d.string(forKey: key("outfit")) ?? "none"
        nextPoop = Date(timeIntervalSince1970: d.double(forKey: key("nextPoop")))
        lastCareDay = d.string(forKey: key("lastCareDay")) ?? ""
        last = Date(timeIntervalSince1970: d.double(forKey: key("last")))
        if d.double(forKey: key("last")) == 0 { last = Date() }
        if d.double(forKey: key("nextPoop")) == 0 { nextPoop = Date().addingTimeInterval(3 * 3600) }
        if d.double(forKey: key("born")) == 0 { d.set(Date().timeIntervalSince1970, forKey: key("born")) }
        born = Date(timeIntervalSince1970: d.double(forKey: key("born")))
        update()
    }

    private func save() {
        d.set(hunger, forKey: key("hunger")); d.set(fun, forKey: key("fun"))
        d.set(health, forKey: key("health")); d.set(sick, forKey: key("sick"))
        d.set(dirt, forKey: key("dirt")); d.set(poops, forKey: key("poops"))
        d.set(bond, forKey: key("bond")); d.set(streak, forKey: key("streak")); d.set(outfit, forKey: key("outfit"))
    }

    var asleep: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return (h >= 23 || h < 7) && reaction == nil && !Pet.forceAwake
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
        if level >= 2 { o += ["bow"] }
        if level >= 3 { o += ["glasses", "flower"] }
        if level >= 4 { o += ["scarf", "bandana"] }
        if level >= 5 { o += ["beanie", "pearls"] }
        if level >= 6 { o += ["crown", "tiara"] }
        if Calendar.current.component(.month, from: Date()) == 12 { o.append("santa") }
        if isBirthday { o.append("party") }
        return o
    }
    /// what she actually wears right now (birthday hat on her birthday if nothing else is on)
    var wearing: String { outfit == "none" && (isBirthday || Date() < Pet.partyUntil) ? "party" : outfit }
    static var partyUntil = Date.distantPast

    // MARK: tricks (unlock with bond)
    static let allTricks = ["sit", "highfive", "beg", "roll"]
    var unlockedTricks: [String] { Array(Pet.allTricks.prefix(min(4, level))) }
    private(set) var currentTrick = "sit"
    private var trickIndex = 0
    func trick() {
        let ts = unlockedTricks
        currentTrick = ts[trickIndex % ts.count]; trickIndex += 1
        fun = min(100, fun + 3)   // just for fun: tricks give no EXP (spammable)
        react(.trick, "🐾", currentTrick == "roll" ? 2.6 : 3)
    }
    /// copy a trick her sister just did (no stats, just for fun)
    func copyTrick(_ name: String) { currentTrick = name; react(.trick, "🐾", name == "roll" ? 2.4 : 2.6) }

    // MARK: birthday (one year after she first showed up)
    private(set) var born: Date = Date()
    var isBirthday: Bool {
        let c = Calendar.current
        let a = c.dateComponents([.month, .day], from: born), b = c.dateComponents([.month, .day], from: Date())
        return (a.month == b.month && a.day == b.day && c.dateComponents([.day], from: born, to: Date()).day ?? 0 > 300) || Pet.forceBirthday
    }
    static var forceBirthday = false
    var ageText: String {
        let days = Calendar.current.dateComponents([.day], from: born, to: Date()).day ?? 0
        return days < 60 ? "\(days)d" : (days < 730 ? "\(days / 30)mo" : "\(days / 365)y")
    }
    private var lastBirthdayParty: String {
        get { d.string(forKey: key("lastBday")) ?? "" } set { d.set(newValue, forKey: key("lastBday")) }
    }
    /// once on her birthday: cake + party
    func birthdayCheck() {
        guard isBirthday, !asleep, reaction == nil else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        if lastBirthdayParty != today || Pet.forceBirthday {
            lastBirthdayParty = today; Pet.forceBirthday = false
            react(.birthday, "🎂", 7); say("🎂 happy birthday \(name)!", 6)
            Pet.partyUntil = Date().addingTimeInterval(60)
        }
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
            lastCareDay = today; d.set(today, forKey: key("lastCareDay"))
            bond += Double(min(streak, 7))                       // daily streak bonus
        }
        let before = level
        bond += points
        if level > before {
            let new = unlockedOutfits.last ?? "none"
            say("❤️ Lv \(level)!" + (level <= 4 ? " new trick" : "") + (new != "none" && new != "santa" ? " + outfit" : ""), 5)
        }
    }

    /// Needs change slowly over real time (also while LimitBar was closed).
    func update() {
        let now = Date()
        let hours = min(now.timeIntervalSince(last) / 3600, 48)   // cap: a long trip away doesn't wreck it
        last = now
        d.set(now.timeIntervalSince1970, forKey: key("last"))
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
            d.set(nextPoop.timeIntervalSince1970, forKey: key("nextPoop"))
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

    // EXP only comes from care she actually NEEDS: feed/play fill a limited bar (EXP scales with how much
    // was filled), clean/bath/medicine only count when there's something to fix. Pat + tricks: no EXP.
    func feed() {
        if hunger >= 90 { say("😋 I'm full!", 2.5); return }
        let gain = min(40, 100 - hunger)
        hunger += gain; fun = min(100, fun + 3); cared(3 * gain / 40)
        nextPoop = min(nextPoop, Date().addingTimeInterval(Double.random(in: 1...2) * 3600))   // what goes in…
        d.set(nextPoop.timeIntervalSince1970, forKey: key("nextPoop"))
        react(.feed, "🍖", 4.5)
    }
    func play() {
        if fun >= 90 { say("😴 don't wanna play", 2.5); return }
        if hunger < 15 { say("🍖 too hungry to play", 2.5); return }
        let gain = min(35, 100 - fun)
        fun += gain; hunger = max(0, hunger - 5); dirt = min(100, dirt + 15); cared(3 * gain / 35)
        react(.play, "🎾", 6)
    }
    func pat() { fun = min(100, fun + 8); react(.pat, "💕", 4) }   // no EXP (spammable)
    func clean() {
        let had = poops
        poops = 0; fun = min(100, fun + 5)
        if had > 0 { cared(Double(min(had, 3))) }
        react(.clean, "✨", 3)
    }
    func bath() {
        let was = dirt
        dirt = 0; fun = min(100, fun + 4)
        if was >= 30 { cared(3 * was / 100) }
        react(.bath, "🫧", 5)
    }
    func medicine() {
        let wasSick = sick
        health = min(100, health + 45)
        if health >= 50 { sick = false }
        if wasSick { cared(2) }
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
                 idleSeconds: Double, limits: [(name: String, used: Double)], tasks: [(id: String, who: String, working: Bool)], speaks: Bool = true) {
        func say(_ t: String, _ secs: Double) { if speaks { self.say(t, secs) } }
        hotCount = cpu > 0.80 ? hotCount + 1 : 0
        cpuHot = hotCount >= 3 || Pet.forceHot                     // ~6 s of heavy CPU
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
            if high, limitHigh[l.name] != true, !asleep { say("⚠️ \(l.name) \(Int(min(999, max(0, l.used.isFinite ? l.used * 100 : 0))))%", 6) }
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

private struct Particle { var x: CGFloat; var y: CGFloat; var vx: CGFloat; var vy: CGFloat; var life: CGFloat; let text: String; let size: CGFloat }

private struct PoodleLook { let fur, hi, dark, cream, sick: NSColor }
private let candieLook = PoodleLook(                                        // brown toy poodle
    fur: NSColor(srgbRed: 0.60, green: 0.38, blue: 0.20, alpha: 1), hi: NSColor(srgbRed: 0.74, green: 0.50, blue: 0.29, alpha: 1),
    dark: NSColor(srgbRed: 0.42, green: 0.25, blue: 0.12, alpha: 1), cream: NSColor(srgbRed: 0.80, green: 0.62, blue: 0.44, alpha: 1),
    sick: NSColor(srgbRed: 0.62, green: 0.56, blue: 0.40, alpha: 1))
private let diorLook = PoodleLook(                                          // black toy poodle (charcoal so she reads on the dark bar)
    fur: NSColor(srgbRed: 0.31, green: 0.30, blue: 0.34, alpha: 1), hi: NSColor(srgbRed: 0.50, green: 0.49, blue: 0.55, alpha: 1),
    dark: NSColor(srgbRed: 0.20, green: 0.19, blue: 0.22, alpha: 1), cream: NSColor(srgbRed: 0.42, green: 0.40, blue: 0.44, alpha: 1),
    sick: NSColor(srgbRed: 0.36, green: 0.36, blue: 0.30, alpha: 1))
private let INK = NSColor(white: 0.04, alpha: 1)

private struct PuffKey: Hashable { let w: Int, h: Int, seed: Int, c: UInt32, hi: UInt32 }
private func rgba(_ c: NSColor?) -> UInt32 {
    guard let c = c?.usingColorSpace(.sRGB) else { return 0 }
    return UInt32(c.redComponent * 255) << 24 | UInt32(c.greenComponent * 255) << 16 | UInt32(c.blueComponent * 255) << 8 | UInt32(c.alphaComponent * 255)
}
private var puffCache: [PuffKey: CGImage] = [:]
/// A curly puff rendered once at 3x into a bitmap; afterwards drawing it is a cheap image stamp.
private func puffImage(_ w: CGFloat, _ h: CGFloat, _ c: NSColor, _ hi: NSColor?, _ seed: Int) -> (CGImage, NSSize)? {
    let pad: CGFloat = 2.6
    let size = NSSize(width: w + pad * 2, height: h + pad * 2)
    let key = PuffKey(w: Int(w * 10), h: Int(h * 10), seed: seed, c: rgba(c), hi: rgba(hi))
    if let img = puffCache[key] { return (img, size) }
    let scale: CGFloat = 3
    guard let cg = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)), bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    cg.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    let cx = size.width / 2, cy = size.height / 2
    let path = NSBezierPath(ovalIn: NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
    let n = max(6, Int((w + h) / 2.0))
    for k in 0..<n {
        let a = Double(k) / Double(n) * 2 * .pi + Double(seed)
        let px = cx + CGFloat(cos(a)) * w * 0.44, py = cy + CGFloat(sin(a)) * h * 0.44
        let rr: CGFloat = 1.5 + CGFloat((k * 7 + seed) % 3) * 0.35
        path.appendOval(in: NSRect(x: px - rr, y: py - rr, width: rr * 2, height: rr * 2))
    }
    c.setFill(); path.fill()
    if let hi {
        let hp = NSBezierPath()
        for k in 0..<max(2, n / 3) {
            let a = Double(k) * 2.4 + Double(seed) * 0.7
            let px = cx + CGFloat(cos(a)) * w * 0.22, py = cy + CGFloat(sin(a)) * h * 0.2 + h * 0.14
            hp.appendOval(in: NSRect(x: px - 0.75, y: py - 0.6, width: 1.5, height: 1.2))
        }
        hi.setFill(); hp.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let img = cg.makeImage() else { return nil }
    if puffCache.count > 400 { puffCache.removeAll() }
    puffCache[key] = img
    return (img, size)
}

/// One dog's animation state (the needs live in `Pet`).
private final class Dog {
    let pet: Pet, look: PoodleLook
    var x: CGFloat, dir: CGFloat = 1, phase = 0.0, pauseUntil = 0.0
    var front = false, chaseV: CGFloat = 0, jumpY: CGFloat = 0, jumpV: CGFloat = 0
    var earLag: CGFloat = 0, lastHeadY: CGFloat = 0, blinkUntil = 0.0, nextBlink = Double.random(in: 1...4)
    var lastAct: Pet.Act? = nil
    var poopXs: [CGFloat] = []
    var sLegH: CGFloat = 5.2, sHX: CGFloat = 0, sHY: CGFloat = 0, sTail: CGFloat = 0.7, sWagAmp: CGFloat = 0.35
    var sWagSpeed = 7.0, wagPhase = Double.random(in: 0...6)
    var sHeadRot: CGFloat = 0, sBodyRot: CGFloat = 0
    var turnS: CGFloat = 0, dirS: CGFloat = 1, bowlA: CGFloat = 0, bowlX: CGFloat = 0
    var settling = false, wasAsleep = false, yawnUntil = 0.0, stretchUntil = 0.0, lastDraw = 0.0
    var vx: CGFloat = 0                         // eased running speed (tag game)
    var passSide: CGFloat = 0                   // ≠0 while walking past her sister (goes behind her), sign = where the sister is
    var lastDirSeen: CGFloat = 1, lastTurnT = -10.0, lastDirT = -10.0
    var committedUntil = 0.0, passUntil = 0.0
    var pendingFace: CGFloat? = nil             // a turn that had to wait for the cooldown
    enum Idle: String, CaseIterable { case sniff, scratch, sneeze, shake, nap, dig }
    var idle: Idle? = nil, idleStart = 0.0, burying = false
    var boneUntil = 0.0                         // carrying a bone she dug up
    var laneBack = false                        // running in the back lane (race)
    var trickStart = 0.0
    var fxNap = false, fxBark = false                    // after deciding (walk past / turn around) she sticks with it — no jitter
    var depth: CGFloat = 0                      // 0 = front lane, 1 = walking behind (drawn a bit higher + smaller)
    var walkSpeed: CGFloat = 0                  // how fast she moved this frame (drives the leg animation)
    // walking somewhere on purpose (to the other dog, to a cuddle spot)
    var goal: CGFloat? = nil, goalRun = false, faceOnArrive: Dog? = nil, frontOnArrive = false
    // interaction pose flags, set fresh every frame by the duo logic
    var fxHappy = false, fxBow = false, fxTongue = false, fxLick = false, fxSad = false  // (+ fxNap, fxBark above)
    init(_ p: Pet, _ l: PoodleLook, x: CGFloat, dir: CGFloat) { pet = p; look = l; self.x = x; self.dir = dir; dirS = dir }
    var mid: CGFloat { x + 14 }
    var free: Bool { pet.reaction == nil && !pet.asleep && !pet.sick && goal == nil }
}

/// The yard: Candie (brown) and Dior (black) live here, wander, nap, and play with each other.
final class PetChip: Chip {
    private var dogs: [Dog] = []
    private var t = 0.0, simF: CGFloat = 0, prevF: CGFloat = 0, s: CGFloat = 1, dtNow = 1.0 / 30
    private var lastTick = CACurrentMediaTime(), lastRestDraw = -1
    private var timer: Timer?
    private let yard: CGFloat = 210
    private let dogW: CGFloat = 28
    private var particles: [Particle] = []
    private var ballOn = false, ballA: CGFloat = 0
    private var ballX: CGFloat = 0, ballY: CGFloat = 0, ballVY: CGFloat = 0, ballVX: CGFloat = 0

    enum DuoKind: String, CaseIterable { case chase, pounce, tug, sit, nap, race, follow }
    private final class Duo {
        let kind: DuoKind; var l: Dog; var r: Dog; let start: Double; var contactAt: Double? = nil
        var runner: Dog; var lastTag = 0.0, restUntil = 0.0, headStartUntil = 0.0
        var bone = false                                        // tug-of-war over a dug-up bone instead of the rope
        var raceDir: CGFloat = 1, spL: CGFloat = 2, spR: CGFloat = 2, doneL = -1.0, doneR = -1.0
        init(_ k: DuoKind, _ l: Dog, _ r: Dog, _ t: Double) { kind = k; self.l = l; self.r = r; start = t; runner = l }
    }
    private var duo: Duo? = nil
    private var nextDuo = 25.0
    // visitors, toys, weather
    private var fly: (x: CGFloat, y: CGFloat, vx: CGFloat, until: Double)? = nil
    private var nextFly = Double.random(in: 90...200)
    private var cat: (x: CGFloat, dir: CGFloat, phase: Double)? = nil
    private var nextCat = Double.random(in: 150...320)
    private var lastBark = 0.0, barker = 0
    private var raining = false, lastWeather = -9999.0, forceRain: Bool? = nil
    private var drops: [CGPoint] = []
    static let weatherOn = false                 // rain + sky were removed at the user's request
    private var daytime: Bool { let h = Calendar.current.component(.hour, from: Date()); return (h >= 7 && h < 21) || Pet.forceAwake }

    override init() {
        super.init()
        setWidth(yard)
        dogs = [Dog(Pet.candie, candieLook, x: 40, dir: 1), Dog(Pet.dior, diorLook, x: 140, dir: -1)]
        let tm = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in self?.step() }
        tm.tolerance = 0.004
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: time helpers (all motion is in "12 fps frames" scaled by real elapsed time, so any frame rate looks the same)
    private func every(_ n: CGFloat) -> Bool { floor(simF / n) != floor(prevF / n) }
    private func chance(_ oneIn: CGFloat) -> Bool { CGFloat.random(in: 0..<1) < s / oneIn }
    private func ease(_ base: CGFloat, _ ds: CGFloat) -> CGFloat { 1 - pow(1 - base, max(0, ds)) }
    private func other(_ d: Dog) -> Dog { dogs[0] === d ? dogs[1] : dogs[0] }
    private func clampX(_ v: CGFloat) -> CGFloat { min(max(v, 3), yard - dogW - 3) }

    static var jitterTurns = 0, totalTurns = 0
    /// test hooks: pile both dogs on one spot walking toward each other / write the turn counters
    func debug(_ cmd: String) {
        switch cmd {
        case "stack":
            duo = nil
            let x = CGFloat.random(in: 40...(yard - 70))
            dogs[0].x = x; dogs[1].x = x + CGFloat.random(in: -4...4)
            dogs[0].dir = 1; dogs[1].dir = -1
            for d in dogs { d.lastDirSeen = d.dir; d.lastDirT = -10; d.lastTurnT = -10 }
            for d in dogs { d.goal = nil; d.pauseUntil = 0; d.passSide = 0; d.committedUntil = 0; d.front = false }
        case "report":
            let st = dogs.map { d in "\(d.pet.name){idle=\(d.idle?.rawValue ?? "-") act=\(String(describing: d.pet.reaction?.kind)) walk=\(String(format: "%.2f", d.walkSpeed)) headY=\(String(format: "%.1f", d.sHY)) legH=\(String(format: "%.1f", d.sLegH)) front=\(d.front) bone=\(d.boneUntil > t)}" }.joined(separator: " ")
            let txt = "turns=\(PetChip.totalTurns) jitter=\(PetChip.jitterTurns) blocked=\(PetChip.blockedTurns) x=\(dogs.map { Int($0.x) }) dir=\(dogs.map { Int($0.dir) }) \(st)\n"
            try? txt.write(toFile: NSHomeDirectory() + "/.hermes/cache/scratch/petdebug.txt", atomically: true, encoding: .utf8)
        case "reset": PetChip.jitterTurns = 0; PetChip.totalTurns = 0; PetChip.blockedTurns = [:]
        case "cat": nextCat = 0
        case "fly": nextFly = 0
        case "rain": forceRain = true; raining = true
        case "dry": forceRain = false; raining = false
        case "bone": let d = dogs[0]; d.boneUntil = t + 25; d.pet.say("🦴!", 2)
        case let c where c.hasPrefix("idle:"):
            if let k = Dog.Idle(rawValue: String(c.dropFirst(5))) { for d in dogs where d.free { startIdle(d, k); break } }
        default: break
        }
    }

    /// test hook / future button: start a play-date right now
    func startDuo(_ name: String) {
        guard let k = DuoKind(rawValue: name) else { return }
        for d in dogs { d.goal = nil; d.pauseUntil = 0 }
        begin(k)
    }

    private var idleSeconds: Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }
    private var onBattery = false, away = false, lastPowerCheck = -10.0

    private func step() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0.001, now - lastTick)); lastTick = now
        // once a second: are you away (Touch Bar dims after ~2 min idle → freeze, 0% CPU)? on battery?
        if now - lastPowerCheck > 1 {
            lastPowerCheck = now
            away = idleSeconds > 120
            if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
               let src = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
                onBattery = src == kIOPSBatteryPowerValue
            }
        }
        if away { return }
        dtNow = dt; t += dt; s = CGFloat(dt * 12); prevF = simF; simF += s
        if every(24) { dogs.forEach { $0.pet.update(); $0.pet.birthdayCheck() } }
        stepWorld()
        for d in dogs { d.fxHappy = false; d.fxBow = false; d.fxTongue = false; d.fxLick = false; d.fxSad = false; d.fxNap = false; d.fxBark = false }
        let x0 = dogs.map { $0.x }
        stepDuo()
        for d in dogs { stepDog(d) }
        let x1 = dogs.map { $0.x }
        keepApart()
        for d in dogs where d.dir != d.lastDirSeen {                           // debug: count jittery turn-arounds
            if t - d.lastDirT < 0.8 { PetChip.jitterTurns += 1 }
            PetChip.totalTurns += 1
            d.lastDirSeen = d.dir; d.lastDirT = t
        }
        for (i, d) in dogs.enumerated() {
            d.phase += Double(abs(d.x - x1[i])) * 0.62                        // stepping aside moves the legs too
            d.walkSpeed = abs(d.x - x0[i]) / max(s, 0.01)
        }
        // the shared ball
        ballOn = dogs.contains { $0.pet.reaction?.kind == .play }
        if ballOn {
            ballVY -= 0.75 * s; ballY += ballVY * s; ballX += ballVX * 1.6 * s
            if ballY <= 2.5 { ballY = 2.5; ballVY = 4.2 }
            if ballX < 8 { ballX = 8; ballVX = abs(ballVX) }
            if ballX > yard - 12 { ballX = yard - 12; ballVX = -abs(ballVX) }
        }
        ballA += ((ballOn ? 1 : 0) - ballA) * ease(0.3, s)
        for k in particles.indices {
            if particles[k].text == "•" { particles[k].vy -= 0.2 * s; if particles[k].y < 3 { particles[k].life = 0 } }
            particles[k].x += particles[k].vx * s; particles[k].y += particles[k].vy * s; particles[k].life -= s
        }
        particles.removeAll { $0.life <= 0 || $0.x < -10 || $0.x > yard + 10 }

        let busy = duo != nil || fly != nil || cat != nil || dogs.contains { $0.idle != nil && $0.idle != .nap } || ballOn || ballA > 0.03 || particles.contains { $0.text != "z" } || dogs.contains {
            $0.settling || $0.walkSpeed > 0.01 || $0.jumpY > 0 || $0.pet.reaction != nil || $0.pet.saying != nil || ($0.pet.cpuHot && !$0.pet.asleep)
                || t < $0.yawnUntil || t < $0.stretchUntil || $0.bowlA > 0.03
        }
        if busy {
            // 24 fps while things move, ~18 on battery
            if !onBattery || every(0.66) { needsDisplay = true }
        } else {
            let f = Int(t * 10)                                   // resting: 10 fps is enough for breathing + tail
            if f != lastRestDraw { lastRestDraw = f; needsDisplay = true }
        }
    }

    // MARK: the world: butterfly, cat, rain
    private func stepWorld() {
        let anyAwake = dogs.contains { !$0.pet.asleep && !$0.pet.sick }
        // weather: ask wttr.in every 30 min (offline → no rain)
        if PetChip.weatherOn, forceRain == nil, t - lastWeather > 1800 {
            lastWeather = t
            if let url = URL(string: "https://wttr.in/?format=%C") {
                var rq = URLRequest(url: url); rq.timeoutInterval = 10
                URLSession.shared.dataTask(with: rq) { [weak self] data, _, _ in
                    let txt = String(data: data ?? Data(), encoding: .utf8)?.lowercased() ?? ""
                    let wet = ["rain", "drizzle", "shower", "thunder"].contains { txt.contains($0) }
                    DispatchQueue.main.async { self?.raining = wet }
                }.resume()
            }
        }
        if raining {
            if drops.count < 44 { drops = (0..<44).map { _ in CGPoint(x: CGFloat.random(in: 0...yard + 20), y: CGFloat.random(in: 0...32)) } }
            for i in drops.indices {
                drops[i].y -= 3.2 * s; drops[i].x -= 0.9 * s
                if drops[i].y < 1 { drops[i] = CGPoint(x: CGFloat.random(in: 0...yard + 20), y: 32) }
            }
        } else if !drops.isEmpty { drops.removeAll() }
        // butterfly
        if fly == nil, t > nextFly, daytime, !raining, anyAwake, duo == nil {
            let fromLeft = Bool.random()
            fly = (fromLeft ? -6 : yard + 6, 16, fromLeft ? 0.7 : -0.7, t + Double.random(in: 12...18))
        }
        if var f = fly {
            f.x += f.vx * s; f.y = 15 + CGFloat(sin(t * 1.6)) * 5 + CGFloat(sin(t * 4.1)) * 1.5
            if t < f.until {
                if chance(45) { f.vx = (Bool.random() ? 1 : -1) * CGFloat.random(in: 0.4...0.9) }
                if f.x < 12 { f.vx = abs(f.vx) } else if f.x > yard - 12 { f.vx = -abs(f.vx) }
            } else { f.vx = (f.x < yard / 2 ? -1 : 1) * 1.1 }                       // flies off
            if t > f.until && (f.x < -10 || f.x > yard + 10) { fly = nil; nextFly = t + Double.random(in: 150...360) } else { fly = f }
        }
        // a cat strolls past in the background
        if cat == nil, t > nextCat, daytime, anyAwake, duo == nil, !ballOn {
            let fromLeft = Bool.random()
            cat = (fromLeft ? -22 : yard + 22, fromLeft ? 1 : -1, 0)
        }
        if var c = cat {
            c.x += c.dir * 0.55 * s; c.phase += Double(0.55 * s) * 0.7
            if c.x < -26 || c.x > yard + 26 { cat = nil; nextCat = t + Double.random(in: 240...480) } else { cat = c }
        }
    }

    private func startIdle(_ d: Dog, _ k: Dog.Idle) {
        d.idle = k; d.idleStart = t; d.front = k == .scratch; d.burying = false
        let dur: Double
        switch k {
        case .sniff: dur = 2.6
        case .scratch: dur = 2.0
        case .sneeze: dur = 1.3
        case .shake: dur = 1.2
        case .nap: dur = Double.random(in: 7...12)
        case .dig: dur = 3.0
        }
        d.pauseUntil = t + dur
    }
    private func endIdle(_ d: Dog) {
        if d.idle == .dig && !d.burying && Int.random(in: 0..<10) < 4 {           // found something!
            d.boneUntil = t + Double.random(in: 18...30); d.pet.say("🦴!", 2.5)
            if d.jumpY == 0 { d.jumpV = 1.5 }
        }
        d.idle = nil; d.burying = false
    }

    /// chase something (ball / butterfly); the dog that isn't the main chaser keeps a body-length back or goes around
    private func chaseTarget(_ d: Dog, _ target: CGFloat, top: CGFloat, primary: Bool, jumpy: Bool) {
        let mouth = d.x + (d.dir > 0 ? dogW - 3 : 3)
        let gap = target - mouth
        if gap * d.dir < -10 { face(d, -d.dir, "chase") }
        let want = max(-top, min(top, gap * 0.16))
        d.chaseV += (want - d.chaseV) * ease(0.25, s)
        let o = other(d)
        if !primary, !passing(d), (o.mid - d.mid) * d.chaseV > 0, abs(o.mid - d.mid) < 36 {
            if abs(target - o.mid) > 30 && (target - o.mid) * d.chaseV > 0 && chance(30) { startPass(d) }
            else { d.chaseV *= max(0, (abs(o.mid - d.mid) - 30) / 6) }
        }
        if abs(gap) > 4 { d.x += d.chaseV * s; d.phase += Double(abs(d.chaseV) * s) * 0.6 + 0.04 * Double(s) }
        if d.jumpY == 0 && abs(gap) < 14 && chance(jumpy ? 25 : 45) { d.jumpV = 2.3 }
        d.fxTongue = true; d.front = false
    }

    private func stepDog(_ d: Dog) {
        let p = d.pet
        if let pf = d.pendingFace, face(d, pf, "pending") { d.pendingFace = nil }
        if d.idle != nil, t >= d.pauseUntil || p.reaction != nil || d.goal != nil || inDuo(d) || ballOn || p.asleep || cat != nil || fly != nil { endIdle(d) }
        // bone time over → bury it
        if d.boneUntil > 0, t > d.boneUntil, d.free, d.idle == nil, !inDuo(d) {
            d.boneUntil = 0; startIdle(d, .dig); d.burying = true
        }
        d.wagPhase += dtNow * d.sWagSpeed
        let act = p.reaction?.kind
        if act != d.lastAct { startAct(d, act); d.lastAct = act }
        if t > d.nextBlink { d.blinkUntil = t + 0.17; d.nextBlink = t + Double.random(in: 2.5...5.5) }

        switch act {
        case .feed?:
            if every(11) { spawn(d.x + (d.dir > 0 ? dogW + CGFloat.random(in: -1...4) : CGFloat.random(in: -8...(-3))), 9, "•", 5, vy: 0.5, vx: CGFloat.random(in: -0.4...0.4)) }
        case .play?:
            chaseBall(d)
        case .pat?:
            if every(10) { let side: CGFloat = Bool.random() ? 1 : -1; spawn(d.mid + side * 12 - 3, 8, "♥", 7, vy: 0.32, vx: side * 0.2) }
        case .med?:
            if every(9) { spawn(d.x + dogW * 0.6, 15, "+", 9, vy: 0.35) }
        case .clean?:
            if every(4), let px = d.poopXs.randomElement() ?? Optional(d.x) { spawn(px + CGFloat.random(in: -2...4), 4, "✦", 7, vy: 0.4) }
            if every(12), !d.poopXs.isEmpty { d.poopXs.removeLast() }
        case .bath?:
            if every(2) { spawn(d.x + CGFloat.random(in: -2...dogW), CGFloat.random(in: 3...16), Bool.random() ? "○" : "●", CGFloat.random(in: 5...9), vy: 0.3, vx: CGFloat.random(in: -0.25...0.25)) }
        case .zoom?:
            d.x += d.dir * 2.2 * s; d.phase += 1.3 * Double(s)
            if d.x <= 4 { face(d, 1, "zoom-wall") } else if d.x >= yard - dogW - 4 { face(d, -1, "zoom-wall") }
            if d.jumpY == 0 && chance(25) { d.jumpV = 2.0 }
        case .greet?, .celebrate?:
            if d.jumpY == 0 && every(9) { d.jumpV = 1.7 }
            if act == .celebrate, every(2) { spawn(CGFloat.random(in: 0...yard), CGFloat.random(in: 18...24), "✦", 6, vy: -0.4, vx: CGFloat.random(in: -0.3...0.3)) }
            if act == .greet, every(10) { spawn(d.mid + CGFloat.random(in: -12...10), 10, "♥", 7, vy: 0.3) }
        case .mail?, .dress?:
            if act == .dress, every(5) { spawn(d.x + CGFloat.random(in: 0...dogW), CGFloat.random(in: 8...20), "✦", 6, vy: 0.2) }
        case .trick?:
            let tt = t - d.trickStart
            if p.currentTrick == "highfive", tt > 0.45, tt - dtNow <= 0.45 { spawn(d.mid + 6, 18, "✦", 8, vy: 0.3) }
            if p.currentTrick == "roll", tt > 1.6, tt - dtNow <= 1.6 { spawn(d.mid - 3, 18, "✦", 8, vy: 0.3) }
        case .birthday?:
            if d.jumpY == 0 && every(10) { d.jumpV = 1.6 }
            if every(3) { spawn(CGFloat.random(in: 0...yard), CGFloat.random(in: 18...24), "✦", 6, vy: -0.4, vx: CGFloat.random(in: -0.3...0.3)) }
        case nil:
            if ballOn && !(p.asleep || p.sick) {
                chaseBall(d)                                               // joins the game
            } else if d.goal != nil {
                walkToGoal(d)
            } else if duo != nil && (duo!.l === d || duo!.r === d) {
                // the play-date drives her
            } else if let c = cat, !(p.asleep || p.sick) {
                // a cat! stop, look at it, bark
                let catMid = c.x + 9
                if abs(catMid - d.mid) > 6 { face(d, catMid > d.mid ? 1 : -1, "cat") }
                d.front = false; d.pauseUntil = t + 1.5; d.fxBark = true
                if t - lastBark > 1.1, dogs[barker] === d {
                    lastBark = t; barker = 1 - barker
                    if Bool.random() || other(d).pet.asleep { p.say("woof!", 0.9); if d.jumpY == 0 { d.jumpV = 1.3 } }
                }
            } else if let f = fly, !(p.asleep || p.sick), d.idle == nil {
                let o = other(d)
                let primary = abs(f.x - d.mid) <= abs(f.x - o.mid) || o.pet.asleep || o.pet.sick
                chaseTarget(d, f.x, top: 1.6, primary: primary, jumpy: true)
            } else if d.idle != nil {
                // doing her little thing (sniffing, scratching, digging…)
                if d.idle == .sniff, every(9) { spawn(d.x + (d.dir > 0 ? dogW + 1 : -3), 3, "·", 7, vy: 0.25, vx: d.dir * 0.2) }
                if d.idle == .dig, every(1.5) { spawn(d.x + (d.dir > 0 ? -2 : dogW - 2), 3, "•", 6.5, vy: CGFloat.random(in: 0.7...1.1), vx: -d.dir * CGFloat.random(in: 0.5...1.2)) }   // flung out behind her
                if d.idle == .sneeze, t - d.idleStart > 0.65, t - d.idleStart - dtNow <= 0.65 { spawn(d.x + (d.dir > 0 ? dogW + 1 : -5), 8, "*", 8, vy: 0.3, vx: d.dir * 0.4) }
                if d.idle == .shake, every(3) { spawn(d.x + CGFloat.random(in: -2...dogW), CGFloat.random(in: 6...14), "·", 7, vy: 0.2, vx: CGFloat.random(in: -0.6...0.6)) }
                if d.idle == .nap, every(40) { spawn(d.x + (d.dir > 0 ? dogW - 2 : 0), 12, "z", 7, vy: 0.14, vx: 0.12 * d.dir) }
            } else if !(p.asleep || p.sick) && t >= d.pauseUntil {
                let speed: CGFloat = (p.fun < 35 || p.batteryLow) ? 0.37 : (p.cpuHot ? 0.5 : 0.75)
                d.x += d.dir * speed * s
                d.phase += Double(speed * s) * 0.62
                if d.x <= 3 { face(d, 1, "wall") } else if d.x >= yard - dogW - 3 { face(d, -1, "wall") }
                // don't walk straight through the other dog: turn around (or stop to look at her)
                let o = other(d)
                let gapO = o.mid - d.mid
                if t >= d.committedUntil, !passing(d), abs(gapO) < 44, gapO * d.dir > 0, !inDuo(o) {
                    // decide ONCE what to do about her sister, then commit for a few seconds
                    let roomBeyond = d.dir > 0 ? (yard - dogW - 3) - o.x > 30 : o.x - 3 > 30
                    let roomBehind = d.dir > 0 ? d.x - 3 > 20 : (yard - dogW - 3) - d.x > 20
                    if abs(gapO) < 30 || (roomBeyond && (Bool.random() || !roomBehind)) {
                        startPass(d)                                              // keep walking, past her (behind)
                    } else if !roomBehind {
                        d.pauseUntil = t + Double.random(in: 1.5...3); d.front = true   // cornered: sit and look at you
                    } else {
                        face(d, -d.dir, "avoid")                                  // or turn around
                        if Bool.random() { d.pauseUntil = t + Double.random(in: 1...2.5); d.front = Bool.random() }
                    }
                    d.committedUntil = t + 3.5
                }
                if chance(170) && !passing(d) {                                    // dogs sit and look around a lot
                    let roll = Int.random(in: 0..<10)
                    if roll < 5 {                                                   // …or do a little dog thing
                        let pool: [Dog.Idle] = d.boneUntil > t ? [.sniff, .scratch, .shake] : [.sniff, .sniff, .scratch, .sneeze, .shake, .dig, .dig, .nap]
                        startIdle(d, pool.randomElement()!)
                    } else {
                        d.pauseUntil = t + Double.random(in: 4...11)
                        d.front = roll < 8
                        if !d.front && Bool.random() { face(d, -d.dir, "pause") }
                    }
                }
            } else if t < d.pauseUntil, d.front, chance(500) {
                d.front = false
            }
            if t >= d.pauseUntil && !(p.asleep || p.sick) && d.goal == nil && !inDuo(d) { d.front = false }
            if p.asleep && d.goal == nil && every(40) { spawn(d.x + (d.dir > 0 ? dogW - 2 : 0), 13, "z", 8, vy: 0.14, vx: 0.12 * d.dir) }
        }
        d.x = clampX(d.x)
        if act != .clean {
            if d.poopXs.count > p.poops { d.poopXs.removeAll() }
            while d.poopXs.count < p.poops { d.poopXs.append(CGFloat.random(in: 6...(yard - 12))) }
        }
        if d.jumpV != 0 || d.jumpY > 0 {
            d.jumpY += d.jumpV * s; d.jumpV -= 0.8 * s
            if d.jumpY <= 0 { d.jumpY = 0; d.jumpV = 0 }
        }
    }

    /// One rule for every situation: never stack on top of each other. Closer is only allowed when it's meant to be
    /// (sleeping together, tug-of-war, sitting together). Too close → they drift apart smoothly.
    private func keepApart() {
        let a = dogs[0], b = dogs[1]
        let snuggling = a.pet.asleep && b.pet.asleep && a.pet.reaction == nil && b.pet.reaction == nil
        var minGap: CGFloat = 32
        if snuggling { minGap = 30 }
        if let du = duo, du.contactAt != nil { minGap = du.kind == .chase ? 30 : 30 }
        if let du = duo, du.kind == .race { return }
        let gap = b.mid - a.mid
        guard abs(gap) < minGap, !(a.goal != nil && b.goal != nil), !passing(a), !passing(b) else { return }
        let push = min(1.4, (minGap - abs(gap)) * 0.25) * s
        // the one that's busy (being fed / petted / played with by you) stays put; the other makes room
        let aFixed = (a.pet.reaction != nil && a.pet.reaction?.kind != .play) || a.goal != nil || inDuo(a) || (a.pet.sick && !b.pet.sick)
        let bFixed = (b.pet.reaction != nil && b.pet.reaction?.kind != .play) || b.goal != nil || inDuo(b) || (b.pet.sick && !a.pet.sick)
        let sign: CGFloat = gap >= 0 ? 1 : -1
        var ma: CGFloat = aFixed ? 0 : (bFixed ? 1 : 0.5), mb: CGFloat = bFixed ? 0 : (aFixed ? 1 : 0.5)
        if aFixed && bFixed { ma = 0.5; mb = 0.5 }
        // up against a wall? the other one moves instead
        if (sign > 0 && a.x <= 4) || (sign < 0 && a.x >= yard - dogW - 4) { mb += ma; ma = 0 }
        if (sign > 0 && b.x >= yard - dogW - 4) || (sign < 0 && b.x <= 4) { ma += mb; mb = 0 }
        // whoever makes room faces the way she's going (decided once, then committed) — no moonwalking, no flip-flopping
        for (d, m, way) in [(a, ma, -sign), (b, mb, sign)] where m > 0 && d.pet.reaction == nil && !d.pet.asleep && !d.fxSad {
            if t >= d.committedUntil, face(d, way, "makeroom") { d.committedUntil = t + 2.5; d.front = false }
        }
        a.x = clampX(a.x - sign * push * ma)
        b.x = clampX(b.x + sign * push * mb)
    }

    private func chaseBall(_ d: Dog) {
        let mine = d.pet.reaction?.kind == .play
        chaseTarget(d, ballX, top: mine ? 2.6 : 2.2, primary: mine, jumpy: false)
    }

    @discardableResult
    private func walkToGoal(_ d: Dog) -> Bool {
        guard let g = d.goal else { return true }
        let dx = g - d.x
        if abs(dx) < 1.5 {
            d.goal = nil
            if let f = d.faceOnArrive { face(d, f.mid >= d.mid ? 1 : -1, "arrive") }
            d.front = d.frontOnArrive
            d.pauseUntil = t + Double.random(in: 4...7)
            return true
        }
        if abs(dx) > 6 { face(d, dx > 0 ? 1 : -1, "goal") }
        let sp: CGFloat = (d.goalRun ? 1.5 : (d.pet.asleep ? 0.4 : 0.75)) * s
        if (dx > 0 ? 1 : -1) == d.dir || abs(dx) <= 6 {                        // walk forward; tiny adjustments may step back
            d.x += (dx > 0 ? 1 : -1) * min(sp, abs(dx)); d.phase += Double(min(sp, abs(dx))) * 0.62
        }
        d.front = false
        return false
    }

    /// The only way a dog turns around. A turn within 0.9 s of the previous one is refused, so no rule can ever
    /// make her flip left-right-left-right. (Blocked requests are counted per rule for debugging.)
    static var blockedTurns: [String: Int] = [:]
    @discardableResult
    private func face(_ d: Dog, _ v: CGFloat, _ why: String, force: Bool = false) -> Bool {
        let v: CGFloat = v >= 0 ? 1 : -1
        if v == d.dir { return true }
        if !force && t - d.lastTurnT < 0.9 {
            PetChip.blockedTurns[why, default: 0] += 1
            if why == "arrive" || why == "duo" || why == "sleep" { d.pendingFace = v }   // do it a moment later
            return false
        }
        d.dir = v; d.lastTurnT = t
        return true
    }

    private func passing(_ d: Dog) -> Bool {
        guard d.passSide != 0 else { return false }
        if t > d.passUntil { d.passSide = 0; return false }
        let o = other(d)
        if (d.mid - o.mid) * d.passSide > 34 { d.passSide = 0; return false }   // made it past: back to the front lane
        return true
    }
    private func startPass(_ d: Dog) { let o = other(d); d.passSide = o.mid >= d.mid ? 1 : -1; d.passUntil = t + 4; if o.passSide != 0 { d.passSide = 0; d.committedUntil = t + 3.5 } }

    private func inDuo(_ d: Dog) -> Bool { duo.map { $0.l === d || $0.r === d } ?? false }

    private func startAct(_ d: Dog, _ a: Pet.Act?) {
        d.front = (a == .pat || a == .med || a == .greet || a == .mail || a == .dress
                   || (a == .trick && (d.pet.currentTrick == "sit" || d.pet.currentTrick == "highfive")))
        if a == .trick { d.trickStart = t }
        if a != nil { if d.idle != nil { endIdle(d) } }
        let sis = other(d)
        if a == .trick, sis.free, !inDuo(sis), sis.pet.reaction == nil, Int.random(in: 0..<10) < 7 {   // sister copies the trick
            let name = d.pet.currentTrick
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { if sis.pet.reaction == nil && !sis.pet.asleep && !sis.pet.sick { sis.pet.copyTrick(name) } }
        }
        if a == .birthday, sis.pet.reaction == nil, !sis.pet.asleep { sis.pet.react(.celebrate, "🎉", 6.5) }
        if a != nil { d.goal = nil; d.pendingFace = nil; if inDuo(d) { endDuo(reward: false) } }
        if a == .play && !ballOn {
            ballX = min(max(d.x + (d.dir > 0 ? dogW + 16 : -16), 8), yard - 12)
            ballY = 12; ballVY = 2; ballVX = d.dir > 0 ? 1.3 : -1.3
        }
        // the other dog notices: jealous when you pet her sister, begging when she eats
        let o = other(d)
        if (a == .pat || a == .feed), o.free, !inDuo(o) {
            var gx = d.mid + (o.mid < d.mid ? -32 : 32) - 14
            if clampX(gx) != gx { gx = d.mid + (o.mid < d.mid ? 32 : -32) - 14 }
            o.goal = clampX(gx); o.goalRun = false; o.pendingFace = nil
            o.faceOnArrive = a == .feed ? d : nil
            o.frontOnArrive = a == .pat                                  // sits facing you: "me too!"
            o.pet.say(a == .pat ? "🥺 me too!" : "👀", 3.5)
        }
    }

    // MARK: play-dates between the two
    private func begin(_ k: DuoKind) {
        let a = dogs[0], b = dogs[1]
        let (l, r) = a.mid <= b.mid ? (a, b) : (b, a)
        let du = Duo(k, l, r, t)
        duo = du
        let c = min(max((l.mid + r.mid) / 2, 34), yard - 34)
        let cc = min(max(c, 50), yard - 50)
        switch k {
        case .pounce:                                                        // face each other, a body-length apart
            l.goal = clampX(cc - 40); r.goal = clampX(cc + 12)
        case .tug:                                                           // rope toy between them
            l.goal = clampX(cc - 36); r.goal = clampX(cc + 8)
        case .sit:                                                           // side by side, both looking at you
            l.goal = clampX(cc - 30); r.goal = clampX(cc + 2)
        case .nap:                                                           // daytime nap, back to back
            l.goal = clampX(cc - 30); r.goal = clampX(cc + 2)
        case .chase:
            du.runner = Bool.random() ? l : r
            du.contactAt = t; du.headStartUntil = t + 0.8
            l.vx = 0; r.vx = 0
        case .race:                                                          // to the far wall, one in the back lane
            du.raceDir = (l.mid + r.mid) / 2 < yard / 2 ? 1 : -1
            du.spL = CGFloat.random(in: 1.8...2.2); du.spR = CGFloat.random(in: 1.8...2.2)
            (Bool.random() ? l : r).laneBack = true
            du.contactAt = t; l.vx = 0; r.vx = 0
            for d in [l, r] { d.pet.say("🏁", 1.2) }
        case .follow:                                                        // follow the leader
            du.runner = Bool.random() ? l : r
            du.contactAt = t
        }
        for d in [l, r] { d.faceOnArrive = (k == .sit || k == .nap) ? nil : other(d); d.frontOnArrive = false; d.goalRun = k == .pounce; d.front = false; d.idle = nil; d.pendingFace = nil }
    }

    private func endDuo(reward: Bool) {
        guard let du = duo else { return }
        for d in [du.l, du.r] {
            d.goal = nil; d.passSide = 0; d.vx = 0; d.laneBack = false; d.pendingFace = nil
            d.pauseUntil = t + Double.random(in: 2...4)
            d.front = reward && Bool.random()
            if reward { d.pet.fun = min(100, d.pet.fun + 6) }
        }
        duo = nil
        nextDuo = t + Double.random(in: 25...60)
    }

    private func stepDuo() {
        let a = dogs[0], b = dogs[1]
        // bedtime: they snuggle up and sleep next to each other
        if a.pet.asleep && b.pet.asleep && a.pet.reaction == nil && b.pet.reaction == nil {
            if duo != nil { endDuo(reward: false) }
            if a.goal == nil && b.goal == nil && abs(abs(a.mid - b.mid) - 32) > 4 {
                let (l, r) = a.mid <= b.mid ? (a, b) : (b, a)
                let c = min(max((l.mid + r.mid) / 2, 34), yard - 34)
                l.goal = clampX(c - 30); r.goal = clampX(c + 2)
                l.faceOnArrive = nil; r.faceOnArrive = nil; l.frontOnArrive = false; r.frontOnArrive = false; l.goalRun = false; r.goalRun = false
            } else if a.goal == nil && b.goal == nil && abs(a.mid - b.mid) > 8 {
                let (l, r) = a.mid <= b.mid ? (a, b) : (b, a)
                face(l, -1, "sleep"); face(r, 1, "sleep")                          // back to back, like sisters
            }
            return
        }
        // one is sick: the other comes and keeps her company
        if a.pet.sick != b.pet.sick {
            let (sick, buddy) = a.pet.sick ? (a, b) : (b, a)
            if duo != nil { endDuo(reward: false) }
            if buddy.pet.reaction == nil, !buddy.pet.asleep, !ballOn {
                let bg = abs(buddy.mid - sick.mid)
                if buddy.goal == nil && (bg > 40 || bg < 31) {
                    var gx = sick.mid + (buddy.mid < sick.mid ? -36 : 36) - 14
                    if clampX(gx) != gx { gx = sick.mid + (buddy.mid < sick.mid ? 36 : -36) - 14 }
                    buddy.goal = clampX(gx); buddy.pendingFace = nil
                    buddy.faceOnArrive = sick; buddy.frontOnArrive = false; buddy.goalRun = false
                } else if buddy.goal == nil {
                    buddy.fxSad = true; buddy.pauseUntil = t + 2; buddy.idle = nil
                    if abs(sick.mid - buddy.mid) > 8 {
                        face(buddy, sick.mid > buddy.mid ? 1 : -1, "buddy")
                        if sick.pet.reaction == nil { face(sick, buddy.mid > sick.mid ? 1 : -1, "sickface") }   // they look at each other
                    }
                }
            }
            return
        }
        guard let du = duo else {
            if a.free && b.free && !ballOn && fly == nil && cat == nil && a.idle == nil && b.idle == nil && t > nextDuo {
                if (a.boneUntil > t || b.boneUntil > t) && Int.random(in: 0..<10) < 6 {
                    begin(.tug); duo?.bone = true                                // "give me that bone!"
                } else { begin(DuoKind.allCases.randomElement()!) }
            }
            return
        }
        // anyone pulled away (you fed / played / petted one) → play-date over
        if du.l.pet.reaction != nil || du.r.pet.reaction != nil || du.l.pet.asleep { endDuo(reward: false); return }
        if du.contactAt == nil {
            if du.l.goal == nil && du.r.goal == nil {
                du.contactAt = t
                if du.kind == .nap { face(du.l, -1, "duo"); face(du.r, 1, "duo") }
                else if du.kind != .sit { face(du.l, 1, "duo"); face(du.r, -1, "duo") }
                du.l.front = false; du.r.front = false
            } else if t - du.start > 8 { endDuo(reward: false) }               // couldn't meet up
            return
        }
        let ct = t - du.contactAt!
        let l = du.l, r = du.r
        l.pauseUntil = t + 1; r.pauseUntil = t + 1
        switch du.kind {
        case .pounce:                                                        // play bows + little hops, taking turns
            let beat = Int(ct / 0.7) % 2
            l.fxTongue = true; r.fxTongue = true
            if beat == 0 { l.fxBow = true } else { r.fxBow = true }
            if every(9) { let j = beat == 0 ? r : l; if j.jumpY == 0 { j.jumpV = 1.7 } }
            l.x = clampX(l.x + CGFloat(sin(t * 4)) * 0.35 * s); r.x = clampX(r.x + CGFloat(sin(t * 4 + 3)) * 0.35 * s)
            if ct > 5 { endDuo(reward: true) }
        case .tug:                                                           // pull pull pull… one wins
            l.fxBow = true; r.fxBow = true; l.fxTongue = false; r.fxTongue = false
            let pull = CGFloat(sin(t * 3.2)) * 0.5 * s
            l.x = clampX(l.x + pull); r.x = clampX(r.x + pull)
            l.sTail = 1.1; r.sTail = 1.1
            if ct > 5 {
                let w = Bool.random() ? l : r
                w.jumpV = 1.8; spawn(w.mid - 3, 18, "✦", 7, vy: 0.3)
                if du.bone { other(w).boneUntil = 0; w.boneUntil = t + Double.random(in: 12...20) }   // winner keeps the bone
                endDuo(reward: true)
            }
        case .nap:
            l.fxNap = true; r.fxNap = true
            if every(40) { let z = Bool.random() ? l : r; spawn(z.x + (z.dir > 0 ? dogW - 2 : 0), 12, "z", 7, vy: 0.14, vx: 0.12 * z.dir) }
            l.pauseUntil = t + 1; r.pauseUntil = t + 1
            if ct > 11 { endDuo(reward: true) }
        case .race:
            for (d, sp) in [(l, du.spL), (r, du.spR)] {
                let done = d === l ? du.doneL : du.doneR
                if done < 0 {
                    face(d, du.raceDir, "race")
                    d.vx += (du.raceDir * sp - d.vx) * ease(0.15, s)
                    d.x = clampX(d.x + d.vx * s); d.phase += Double(abs(d.vx) * s) * 0.62
                    d.fxTongue = true
                    if (du.raceDir > 0 && d.x >= yard - dogW - 4) || (du.raceDir < 0 && d.x <= 4) {
                        if d === l { du.doneL = t } else { du.doneR = t }
                    }
                } else { d.vx = 0; d.fxTongue = true }
            }
            if (du.doneL >= 0 && du.doneR >= 0) || ct > 7 {
                let w = du.doneR < 0 || (du.doneL >= 0 && du.doneL <= du.doneR) ? l : r
                if w.jumpY == 0 { w.jumpV = 2.0 }
                spawn(w.mid - 3, 18, "✦", 8, vy: 0.3)
                endDuo(reward: true)
            }
        case .follow:
            let lead = du.runner, fol = other(lead)
            // leader strolls, bouncing off the walls (walks past her sister if she's in the way)
            if (lead.x <= 4 && lead.dir < 0) || (lead.x >= yard - dogW - 4 && lead.dir > 0) {
                du.runner = fol                                                   // wall: swap — the follower leads the way back
                face(fol, lead.dir < 0 ? 1 : -1, "follow-swap"); face(lead, lead.dir < 0 ? 1 : -1, "follow-swap")
                return
            }
            lead.x = clampX(lead.x + lead.dir * 0.8 * s); lead.phase += Double(0.8 * s) * 0.62
            // follower stays a body-length behind
            let spot = lead.mid - lead.dir * 38
            let dx = spot - fol.mid
            if abs(dx) > 3 {
                if face(fol, dx > 0 ? 1 : -1, "follow") || (dx > 0 ? 1 : -1) == fol.dir {
                    let st = min(abs(dx), 0.95 * s); fol.x = clampX(fol.x + (dx > 0 ? 1 : -1) * st); fol.phase += Double(st) * 0.62
                }
            }
            lead.fxTongue = true; fol.fxHappy = Int(ct * 2) % 5 == 0
            if ct > 9 { endDuo(reward: true) }
        case .sit:                                                           // sitting together, wagging
            if ct < 0.1 { l.front = true; r.front = true }
            l.fxHappy = ct > 1.5 && Int(ct) % 3 == 0; r.fxHappy = ct > 1.5 && Int(ct + 1.5) % 3 == 0
            if ct > 6 { endDuo(reward: true) }
        case .chase:                                                         // tag, you're it!
            let runner = du.runner, chaser = other(runner)
            runner.fxTongue = true; chaser.fxTongue = true
            let gap = runner.mid - chaser.mid
            var vr: CGFloat = 0, vc: CGFloat = 0
            if t >= du.restUntil {
                // runner flees toward open space; chaser follows after its head start
                let away: CGFloat = gap >= 0 ? 1 : -1
                let cornered = (away > 0 && runner.x >= yard - dogW - 8) || (away < 0 && runner.x <= 8)
                if cornered && !passing(runner) && abs(gap) > 31 { startPass(runner) }   // dodge past the chaser!
                let dodge = passing(runner)
                vr = dodge ? -away * 1.8 : away * 1.6
                vc = t >= du.headStartUntil ? (gap >= 0 ? 1 : -1) * (dodge ? 0.9 : 1.9) : 0
                if abs(gap) < 31 && t >= du.headStartUntil && !dodge {      // caught (a body-length apart, never on top)
                    du.lastTag = t; du.runner = chaser
                    du.restUntil = t + 0.7; du.headStartUntil = t + 1.4
                    if runner.jumpY == 0 { runner.jumpV = 1.4 }
                }
            }
            // ease speeds: they slow down, stop, then turn and take off (no snapping)
            runner.vx += (vr - runner.vx) * ease(0.12, s); chaser.vx += (vc - chaser.vx) * ease(0.12, s)
            for d in [runner, chaser] {
                d.x = clampX(d.x + d.vx * s); d.phase += Double(abs(d.vx) * s) * 0.62
                if abs(d.vx) > 0.15 { face(d, d.vx, "tag") }
                else if t >= du.restUntil - 0.2, abs(other(d).mid - d.mid) > 8 {   // about to go: face the right way while standing
                    let o = other(d)
                    face(d, (d === du.runner) == (o.mid > d.mid) ? -1 : 1, "tag-rest")
                }
            }
            if ct > 9 { endDuo(reward: true) }
        }
    }

    private func spawn(_ x0: CGFloat, _ y0: CGFloat, _ str: String, _ size: CGFloat, vy: CGFloat, vx: CGFloat = 0) {
        particles.append(Particle(x: x0, y: y0, vx: vx * 1.6, vy: vy * 1.6, life: 20, text: str, size: size))
    }

    // MARK: drawing

    override func drawContent(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // (no sky backdrop: the user prefers the plain dark chip)
        drawCat(r, ctx)
        drawCake(r)
        for d in dogs { drawProps(d, r, ctx) }
        NSBezierPath(rect: r).addClip()                                       // nothing leaks outside the yard
        for d in dogs { d.depth += ((passing(d) || d.laneBack ? 1 : 0) - d.depth) * 0.25 }
        // back lane first, then the one facing you on top
        for d in dogs.sorted(by: { ($0.depth > 0.5 ? 0 : 1, $0.turnS) < ($1.depth > 0.5 ? 0 : 1, $1.turnS) }) { drawDog(d, r, ctx) }
        if let du = duo, du.kind == .tug, du.contactAt != nil {
            let a = NSPoint(x: r.minX + du.l.x + 26, y: r.minY + 10.5 + du.l.jumpY)
            let b = NSPoint(x: r.minX + du.r.x + 2, y: r.minY + 10.5 + du.r.jumpY)
            if du.bone {
                drawBone(at: NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), w: max(6, b.x - a.x - 2))
            } else {
                let rope = NSBezierPath(); rope.move(to: a)
                rope.curve(to: b, controlPoint1: NSPoint(x: a.x + 4, y: a.y - 2), controlPoint2: NSPoint(x: b.x - 4, y: b.y - 2))
                rope.lineWidth = 1.8; rope.lineCapStyle = .round
                NSColor(srgbRed: 0.95, green: 0.30, blue: 0.32, alpha: 1).setStroke(); rope.stroke()
                rope.lineWidth = 0.7; rope.setLineDash([1.2, 1.6], count: 2, phase: 0); NSColor.white.setStroke(); rope.stroke()
            }
        }

        drawButterfly(r)
        if ballA > 0.03 {
            if !ballOn { ballY = max(2.5, ballY - 1.5) }
            NSColor(srgbRed: 0.80, green: 0.95, blue: 0.22, alpha: min(1, ballA)).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + ballX, y: r.minY + ballY, width: 5, height: 5)).fill()
        }
        for p in particles where p.life >= 5 {
            let c: NSColor
            switch p.text {
            case "♥": c = .systemPink
            case "+": c = workingGreen
            case "!": c = .systemYellow
            case "z": c = NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 1)
            case "·": c = NSColor(white: 0.80, alpha: 0.9)
            case "*": c = NSColor(white: 0.95, alpha: 1)
            case "○", "●": c = NSColor(srgbRed: 0.70, green: 0.88, blue: 1, alpha: 1)
            case "✦": c = [NSColor.systemYellow, .systemPink, toolTeal, .systemOrange][((Int(p.size * 10) + Int(abs(p.vx) * 50)) % 4 + 4) % 4]
            default: c = NSColor(srgbRed: 0.65, green: 0.45, blue: 0.25, alpha: 1)
            }
            if let (img, sz) = glyphImage(p.text, p.size, c) {
                ctx.draw(img, in: CGRect(x: r.minX + p.x, y: r.minY + p.y, width: sz.width, height: sz.height))
            }
        }
        // sweat drops when the CPU is cooking: slide down smoothly and fade, two at a time
        for (di, d) in dogs.enumerated() where d.pet.cpuHot && !d.pet.asleep {
            for k in 0..<2 {
                let ph = (t * 0.7 + Double(k) * 0.5 + Double(di) * 0.27).truncatingRemainder(dividingBy: 1)
                let side: CGFloat = k == 0 ? 1 : -1
                let baseX = d.turnS > 0.5 ? dogW / 2 + side * 6 : (d.dir > 0 ? dogW - 8 - CGFloat(k) * 5 : 8 + CGFloat(k) * 5)
                let sx = r.minX + d.x + baseX, sy = r.minY + 21 - CGFloat(ph) * 7
                let alpha = CGFloat(ph < 0.15 ? ph / 0.15 : (ph > 0.75 ? (1 - ph) / 0.25 : 1)) * 0.9
                NSColor(srgbRed: 0.45, green: 0.75, blue: 1.0, alpha: alpha).setFill()
                let dp = NSBezierPath(); dp.move(to: NSPoint(x: sx, y: sy + 2.6))
                dp.curve(to: NSPoint(x: sx, y: sy), controlPoint1: NSPoint(x: sx - 1.6, y: sy + 0.6), controlPoint2: NSPoint(x: sx - 1.2, y: sy))
                dp.curve(to: NSPoint(x: sx, y: sy + 2.6), controlPoint1: NSPoint(x: sx + 1.2, y: sy), controlPoint2: NSPoint(x: sx + 1.6, y: sy + 0.6))
                dp.fill()
            }
        }
        // words: what they're saying beats what they need; needs take turns so the bar never gets crowded
        let needers = dogs.filter { $0.pet.need != nil && $0.pet.reaction == nil && !$0.pet.asleep && $0.pet.saying == nil }
        let cyc = Int(t / 1.4)
        let needDog: Dog? = needers.isEmpty || cyc % 3 == 2 ? nil : needers[(cyc / 3) % needers.count]
        for d in dogs {
            guard let n = d.pet.saying?.text ?? (d === needDog ? d.pet.need : nil) else { continue }
            let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.85); sh.shadowBlurRadius = 1.5; sh.shadowOffset = .zero
            let a = NSAttributedString(string: n, attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
                                                               .foregroundColor: NSColor(white: 0.97, alpha: 1), .shadow: sh])
            let bx = r.minX + d.mid + (d.turnS > 0.5 ? 0 : d.dir * 4) - a.size().width / 2   // centred over the one talking
            a.draw(at: NSPoint(x: max(r.minX + 2, min(bx, r.maxX - a.size().width - 2)), y: r.maxY - a.size().height - 0.5))
        }
    }

    /// particles (♥ ✦ z • …) are rendered once per glyph/size/colour, then stamped — CoreText every frame is expensive
    private var glyphCache: [String: (CGImage, NSSize)] = [:]
    private func glyphImage(_ text: String, _ size: CGFloat, _ color: NSColor) -> (CGImage, NSSize)? {
        let key = "\(text)|\(size)|\(rgba(color))"
        if let g = glyphCache[key] { return g }
        let a = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color])
        let sz = a.size(); let scale: CGFloat = 3
        guard sz.width > 0, let cg = CGContext(data: nil, width: Int(ceil(sz.width * scale)), height: Int(ceil(sz.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        a.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        guard let img = cg.makeImage() else { return nil }
        if glyphCache.count > 200 { glyphCache.removeAll() }
        glyphCache[key] = (img, sz)
        return (img, sz)
    }

    private func drawBone(at c: NSPoint, w: CGFloat) {
        NSColor(white: 0.95, alpha: 1).setFill()
        let bp = NSBezierPath(roundedRect: NSRect(x: c.x - w / 2, y: c.y - 0.75, width: w, height: 1.5), xRadius: 0.7, yRadius: 0.7)
        for sx in [-1.0, 1.0] as [CGFloat] { for sy in [-1.0, 1.0] as [CGFloat] {
            bp.appendOval(in: NSRect(x: c.x + sx * w / 2 - 1.1, y: c.y + sy * 0.8 - 1.1, width: 2.2, height: 2.2)) } }
        bp.fill()
    }

    /// sky behind everything: dawn / day / sunset / night (+ moon & stars), a hint of ground, rain when it rains
    private func skyColors(_ h: Double) -> (NSColor, NSColor) {
        typealias C = (CGFloat, CGFloat, CGFloat)
        let keys: [(Double, C, C)] = [
            (0, (0.04, 0.05, 0.12), (0.07, 0.08, 0.15)), (5.5, (0.04, 0.05, 0.12), (0.07, 0.08, 0.15)),
            (7, (0.16, 0.18, 0.36), (0.45, 0.28, 0.26)), (9, (0.17, 0.36, 0.60), (0.33, 0.50, 0.66)),
            (16.5, (0.17, 0.36, 0.60), (0.33, 0.50, 0.66)), (18.6, (0.18, 0.14, 0.34), (0.50, 0.25, 0.16)),
            (20.5, (0.04, 0.05, 0.12), (0.07, 0.08, 0.15)), (24, (0.04, 0.05, 0.12), (0.07, 0.08, 0.15))]
        var i = 0; while i < keys.count - 2 && h >= keys[i + 1].0 { i += 1 }
        let (h0, a0, b0) = keys[i], (h1, a1, b1) = keys[i + 1]
        let f = CGFloat(max(0, min(1, (h - h0) / max(0.01, h1 - h0))))
        func mix(_ x: C, _ y: C) -> NSColor { NSColor(srgbRed: x.0 + (y.0 - x.0) * f, green: x.1 + (y.1 - x.1) * f, blue: x.2 + (y.2 - x.2) * f, alpha: 1) }
        var top = mix(a0, a1), bot = mix(b0, b1)
        if raining { top = top.blended(withFraction: 0.6, of: NSColor(white: 0.20, alpha: 1))!; bot = bot.blended(withFraction: 0.6, of: NSColor(white: 0.22, alpha: 1))! }
        return (top, bot)
    }
    private var skyCache: (key: String, img: CGImage)? = nil
    private func skyBackdrop(_ r: NSRect, _ h: Double, _ top: NSColor, _ bot: NSColor, _ night: Bool) -> CGImage? {
        let key = "\(Int(h * 12))|\(raining)|\(Int(r.width))x\(Int(r.height))"
        if let c = skyCache, c.key == key { return c.img }
        let scale: CGFloat = 2
        guard let cg = CGContext(data: nil, width: Int(r.width * scale), height: Int(r.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        let lr = NSRect(origin: .zero, size: r.size)
        NSBezierPath(roundedRect: lr, xRadius: 6, yRadius: 6).addClip()
        NSGradient(starting: bot, ending: top)?.draw(in: lr, angle: 90)
        NSColor(white: 0, alpha: 0.28).setFill()
        NSRect(x: 0, y: 0, width: lr.width, height: 3.2).fill()
        let grass = NSBezierPath()
        for i in 0..<14 {
            let gx = 6 + CGFloat(i) * (lr.width - 12) / 13 + CGFloat((i * 7) % 5)
            grass.move(to: NSPoint(x: gx, y: 2.4)); grass.line(to: NSPoint(x: gx - 0.8, y: 4.6))
            grass.move(to: NSPoint(x: gx + 1, y: 2.4)); grass.line(to: NSPoint(x: gx + 1.6, y: 4.2))
        }
        grass.lineWidth = 0.6; NSColor(srgbRed: 0.35, green: 0.55, blue: 0.35, alpha: night ? 0.35 : 0.55).setStroke(); grass.stroke()
        NSGraphicsContext.restoreGraphicsState()
        guard let img = cg.makeImage() else { return nil }
        skyCache = (key, img)
        return img
    }
    private func drawSky(_ r: NSRect, _ ctx: CGContext) {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        var h = Double(comps.hour ?? 12) + Double(comps.minute ?? 0) / 60
        if Pet.forceAwake && (h >= 21 || h < 7) { h = 12 }                       // test hook: pretend it's day
        let (top, bot) = skyColors(h)
        let nightSky = h >= 20.5 || h < 6
        ctx.saveGState()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).addClip()
        if let img = skyBackdrop(r, h, top, bot, nightSky) { ctx.draw(img, in: r) }
        let night = h >= 20.5 || h < 6
        if night && !raining {
            for i in 0..<10 {                                                   // twinkling stars
                let sx = r.minX + CGFloat((i * 53 + 17) % Int(max(1, r.width - 10))) + 5
                let sy = r.minY + 14 + CGFloat((i * 37) % 13)
                let a = 0.25 + 0.45 * abs(sin(t * 0.7 + Double(i) * 1.7))
                NSColor(white: 1, alpha: a).setFill()
                NSBezierPath(ovalIn: NSRect(x: sx, y: sy, width: 1.1, height: 1.1)).fill()
            }
            let mc = NSPoint(x: r.maxX - 16, y: r.maxY - 8)                     // crescent moon
            NSColor(srgbRed: 1, green: 0.96, blue: 0.82, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: mc.x - 3.2, y: mc.y - 3.2, width: 6.4, height: 6.4)).fill()
            top.setFill(); NSBezierPath(ovalIn: NSRect(x: mc.x - 1.6, y: mc.y - 2.2, width: 6.0, height: 6.0)).fill()
        } else if !raining && h >= 6.5 && h < 19.5 {                            // the sun crossing the sky
            let pr = CGFloat((h - 6.5) / 13)
            let sc = NSPoint(x: r.minX + 10 + pr * (r.width - 20), y: r.minY + 18 + sin(pr * .pi) * 6)
            NSColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: sc.x - 5, y: sc.y - 5, width: 10, height: 10)).fill()
            NSColor(srgbRed: 1, green: 0.90, blue: 0.40, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: sc.x - 3, y: sc.y - 3, width: 6, height: 6)).fill()
        }
        ctx.restoreGState()
    }
    private func drawRain(_ r: NSRect) {
        guard !drops.isEmpty else { return }
        let rp = NSBezierPath()
        for dp in drops { rp.move(to: NSPoint(x: r.minX + dp.x, y: r.minY + dp.y)); rp.line(to: NSPoint(x: r.minX + dp.x + 1.4, y: r.minY + dp.y + 5)) }
        rp.lineWidth = 0.7; NSColor(srgbRed: 0.7, green: 0.82, blue: 1, alpha: 0.7).setStroke(); rp.stroke()
    }
    private func drawCat(_ r: NSRect, _ ctx: CGContext) {
        guard let c = cat else { return }
        ctx.saveGState()
        ctx.translateBy(x: r.minX + c.x + 9, y: r.minY + 5.5)               // back lane: a bit higher
        ctx.scaleBy(x: c.dir * 0.78, y: 0.78); ctx.setAlpha(0.92)
        let fur = NSColor(srgbRed: 0.93, green: 0.62, blue: 0.30, alpha: 1), dark = NSColor(srgbRed: 0.75, green: 0.45, blue: 0.20, alpha: 1)
        let ph = c.phase * 6
        let lp = NSBezierPath()                                                 // legs
        for (hx, o) in [(-5.5, 0.0), (-3.5, 3.1), (4.0, 3.1), (6.0, 0.0)] as [(CGFloat, Double)] {
            let sw = CGFloat(sin(ph + o)) * 1.4
            lp.move(to: NSPoint(x: hx, y: 4)); lp.line(to: NSPoint(x: hx + sw, y: 0.4))
        }
        lp.lineWidth = 1.8; lp.lineCapStyle = .round; dark.setStroke(); lp.stroke()
        let tail = NSBezierPath(); tail.move(to: NSPoint(x: -7.5, y: 6))         // tail up, swishing
        tail.curve(to: NSPoint(x: -10 + CGFloat(sin(t * 3)) * 1.5, y: 13), controlPoint1: NSPoint(x: -11, y: 6), controlPoint2: NSPoint(x: -9, y: 11))
        tail.lineWidth = 1.6; tail.lineCapStyle = .round; fur.setStroke(); tail.stroke()
        fur.setFill(); NSBezierPath(ovalIn: NSRect(x: -8.5, y: 3, width: 17, height: 7)).fill()
        dark.setFill(); for k in 0..<3 { NSRect(x: -4 + CGFloat(k) * 3, y: 7.5, width: 1, height: 2.4).fill() }   // tabby stripes
        fur.setFill(); NSBezierPath(ovalIn: NSRect(x: 5.5, y: 6.5, width: 7, height: 6.5)).fill()
        let ears = NSBezierPath()
        ears.move(to: NSPoint(x: 6.4, y: 11.5)); ears.line(to: NSPoint(x: 7.2, y: 15)); ears.line(to: NSPoint(x: 9, y: 12.4)); ears.close()
        ears.move(to: NSPoint(x: 9.6, y: 12.4)); ears.line(to: NSPoint(x: 11.6, y: 14.6)); ears.line(to: NSPoint(x: 12, y: 11)); ears.close()
        ears.fill()
        INK.setFill(); NSBezierPath(ovalIn: NSRect(x: 9.8, y: 9.4, width: 1.3, height: 1.6)).fill()
        NSColor.systemPink.setFill(); NSBezierPath(ovalIn: NSRect(x: 12, y: 8.6, width: 1, height: 0.8)).fill()
        ctx.restoreGState()
    }
    private func drawButterfly(_ r: NSRect) {
        guard let f = fly else { return }
        let x = r.minX + f.x, y = r.minY + f.y
        let flap = CGFloat(abs(sin(t * 14))) * 1.5
        NSColor(srgbRed: 1.0, green: 0.55, blue: 0.80, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 3.4 * flap - 0.3, y: y - 0.4, width: 3.4 * flap + 0.6, height: 4.6)).fill()
        NSBezierPath(ovalIn: NSRect(x: x - 0.3, y: y - 0.4, width: 3.4 * flap + 0.6, height: 4.6)).fill()
        NSColor(srgbRed: 1.0, green: 0.85, blue: 0.4, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 2.4 * flap - 0.2, y: y - 3.0, width: 2.4 * flap + 0.4, height: 3.0)).fill()
        NSBezierPath(ovalIn: NSRect(x: x - 0.2, y: y - 3.0, width: 2.4 * flap + 0.4, height: 3.0)).fill()
        NSColor(white: 0.15, alpha: 1).setFill(); NSRect(x: x - 0.4, y: y - 3.0, width: 0.8, height: 6).fill()
    }
    private var cakeX: CGFloat? = nil
    private func drawCake(_ r: NSRect) {
        guard dogs.contains(where: { $0.pet.reaction?.kind == .birthday }) else { cakeX = nil; return }
        if cakeX == nil {                                                    // put it where nobody's standing
            cakeX = stride(from: CGFloat(14), through: yard - 14, by: 4).max { a, b in
                dogs.map { abs($0.mid - a) }.min()! < dogs.map { abs($0.mid - b) }.min()! }
        }
        let cx = r.minX + (cakeX ?? yard / 2), by = r.minY + 2.5
        NSColor(srgbRed: 0.95, green: 0.55, blue: 0.70, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: cx - 7, y: by, width: 14, height: 6), xRadius: 1.5, yRadius: 1.5).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: cx - 7.4, y: by + 5, width: 14.8, height: 2.2), xRadius: 1.1, yRadius: 1.1).fill()
        NSColor(srgbRed: 0.5, green: 0.75, blue: 1, alpha: 1).setFill(); NSRect(x: cx - 0.5, y: by + 7.2, width: 1, height: 3.4).fill()
        let fl = CGFloat(sin(t * 20)) * 0.3
        NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - 1 + fl, y: by + 10.4, width: 2, height: 2.8)).fill()
        NSColor.systemYellow.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - 0.5 + fl, y: by + 10.8, width: 1, height: 1.6)).fill()
    }

    private func drawProps(_ d: Dog, _ r: NSRect, _ ctx: CGContext) {
        let kind = d.pet.reaction?.kind
        if kind == .feed { d.bowlX = d.dir > 0 ? d.x + dogW - 3 : d.x - 9 }
        if d.bowlA > 0.03 {
            ctx.saveGState(); ctx.setAlpha(min(1, d.bowlA))
            let bx = r.minX + d.bowlX
            NSColor(srgbRed: 0.86, green: 0.26, blue: 0.28, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: bx, y: r.minY + 2.5, width: 12, height: 4.5), xRadius: 2.2, yRadius: 2.2).fill()
            NSColor(srgbRed: 1.0, green: 0.55, blue: 0.55, alpha: 1).setFill()
            NSRect(x: bx + 1, y: r.minY + 6.2, width: 10, height: 0.8).fill()
            NSColor(srgbRed: 0.55, green: 0.33, blue: 0.16, alpha: 1).setFill()
            let kib = NSBezierPath()
            for (dx, dy) in [(2.5, 5.6), (4.6, 6.3), (6.8, 6.0), (8.6, 5.5), (5.6, 7.2)] as [(CGFloat, CGFloat)] {
                kib.appendOval(in: NSRect(x: bx + dx, y: r.minY + dy, width: 2.0, height: 1.7))
            }
            kib.fill()
            ctx.restoreGState()
        }
        for (i, px) in d.poopXs.enumerated() {
            let bx = r.minX + px
            NSColor(srgbRed: 0.40, green: 0.24, blue: 0.10, alpha: 1).setFill()
            let pp = NSBezierPath()
            pp.appendOval(in: NSRect(x: bx, y: r.minY + 2.5, width: 7, height: 3))
            pp.appendOval(in: NSRect(x: bx + 1.2, y: r.minY + 4.6, width: 4.6, height: 2.6))
            pp.appendOval(in: NSRect(x: bx + 2.4, y: r.minY + 6.4, width: 2.4, height: 2.0))
            pp.fill()
            let stink = NSBezierPath()
            for k in 0..<2 {
                let sx = bx + 2 + CGFloat(k) * 3, w = CGFloat(sin(t * 3 + Double(i + k)))
                stink.move(to: NSPoint(x: sx, y: r.minY + 9)); stink.curve(to: NSPoint(x: sx + w, y: r.minY + 14),
                    controlPoint1: NSPoint(x: sx + 1.5, y: r.minY + 10.5), controlPoint2: NSPoint(x: sx - 1.5, y: r.minY + 12.5))
            }
            stink.lineWidth = 0.6; NSColor(srgbRed: 0.6, green: 0.75, blue: 0.4, alpha: 0.8).setStroke(); stink.stroke()
        }
    }

    private func drawDog(_ d: Dog, _ r: NSRect, _ ctx: CGContext) {
        let pet = d.pet
        let ds = CGFloat(min(3, max(0, (t - d.lastDraw) * 12))); d.lastDraw = t
        let kind = pet.reaction?.kind
        let walking = d.walkSpeed > 0.05
        let running = d.walkSpeed > 1.2 || kind == .play || kind == .zoom
        let asleep = pet.asleep && kind == nil && !walking
        let sick = pet.sick && kind == nil

        d.bowlA += ((kind == .feed ? 1 : 0) - d.bowlA) * ease(0.25, ds)

        let ph = d.phase
        let swing: CGFloat = walking ? CGFloat(sin(ph)) * (running ? 0.75 : 0.5) : 0
        var legH: CGFloat = 5.2
        var bodyBob: CGFloat = walking ? CGFloat(abs(sin(ph))) * 0.8 : 0
        var headDX: CGFloat = 0, headDY: CGFloat = 0
        var osc: CGFloat = walking ? CGFloat(sin(ph * 2)) * 0.45 : 0
        var tailUp: CGFloat = 0.7, wagSpeed = 7.0, wagAmp: CGFloat = 0.35
        var eyesClosed = t < d.blinkUntil, happyEyes = false, tongue = false
        var shiver: CGFloat = 0
        var frontKick: CGFloat = 0, backKick: CGFloat = 0, backLift: CGFloat = 0, bodyRot: CGFloat = 0
        var rotPivot = NSPoint(x: 8, y: 2), pawRaise: CGFloat = 0
        var panting = false, droopy = false, sadEyes = false
        var headRot: CGFloat = 0, scratching = false
        let breathe = CGFloat(sin(t * 1.8 + (d === dogs[1] ? 1.3 : 0))) * 0.35
        let flick = Int(t * 12) % 2 == 0

        switch kind {
        case .feed?:
            headDX = 3.4; headDY = -8.4; osc = CGFloat(sin(t * 11)) * 0.8
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
            shiver = CGFloat(sin(t * 28)) * 0.8; eyesClosed = true; tailUp = 0.2
        case .clean?, .dress?:
            happyEyes = kind == .dress; tailUp = 1.0; wagSpeed = 12; wagAmp = 0.5
        case .zoom?, .greet?, .celebrate?:
            tongue = true; happyEyes = kind != .zoom; tailUp = 1.1; wagSpeed = 18; wagAmp = 0.6
        case .mail?:
            tailUp = 1.0; wagSpeed = 14; wagAmp = 0.5
        case .birthday?:
            tongue = true; happyEyes = true; tailUp = 1.1; wagSpeed = 18; wagAmp = 0.6
        case .trick?:
            let tt = CGFloat(t - d.trickStart)
            tailUp = 1.0; wagSpeed = 15; wagAmp = 0.55
            switch pet.currentTrick {
            case "highfive":
                pawRaise = min(1, tt / 0.45) * (tt < 2.3 ? 1 : max(0, 1 - (tt - 2.3) / 0.4))
                happyEyes = tt > 0.6; tongue = tt > 0.6
            case "beg":                                                       // up on her back legs, paws in the air
                bodyRot = min(1, tt / 0.4) * (tt < 2.5 ? 1 : max(0, 1 - (tt - 2.5) / 0.4)) * 0.42
                rotPivot = NSPoint(x: 7, y: 2); tongue = true; happyEyes = tt > 1
            case "roll":                                                      // roll over!
                let pr = max(0, min(1, (tt - 0.25) / 1.2))
                bodyRot = -pr * 2 * .pi; rotPivot = NSPoint(x: 12, y: 7)
                eyesClosed = pr > 0 && pr < 1; happyEyes = pr >= 1; tongue = pr >= 1
            default:                                                          // sit (front view)
                happyEyes = tt > 0.7
            }
        case nil:
            if asleep {
                legH = 1.2; headDX = 1.0; headDY = -4.2; osc = breathe * 0.6; eyesClosed = true
                tailUp = -0.5; wagSpeed = 0.8; wagAmp = 0.06; bodyBob = breathe
            } else if sick {
                headDY = -2.2; tailUp = -0.9; wagSpeed = 1.2; wagAmp = 0.08
                shiver = CGFloat(sin(t * 24)) * 0.35
            } else if !walking {
                tailUp = pet.fun < 35 ? -0.2 : 0.7; wagSpeed = pet.fun < 35 ? 2 : 6
                osc = CGFloat(sin(t * 0.9)) * 0.4 + breathe * 0.4
            } else if pet.fun < 35 { tailUp = -0.1; wagSpeed = 2.5 }
            if pet.cpuHot && !asleep {                                         // hot: panting, droopy, lazy tail
                let pant = CGFloat(sin(t * 10))
                tongue = true; panting = true
                osc += pant * 0.45; bodyBob += abs(pant) * 0.35
                tailUp = min(tailUp, 0.25); wagSpeed = 3.5; wagAmp = 0.2
                if !happyEyes && !eyesClosed { droopy = true }
            }
            if pet.batteryLow && !asleep { wagSpeed = min(wagSpeed, 2); if Int(t * 2) % 5 == 0 { eyesClosed = true } }
            if running { tongue = true; tailUp = 1.0; wagSpeed = 14; wagAmp = 0.5 }
            if let idle = d.idle, !walking {
                let it = CGFloat(t - d.idleStart)
                switch idle {
                case .sniff:                                                  // nose right down in the grass
                    headDX = 4.2; headDY = -9.6; headRot = -0.38; osc = CGFloat(sin(t * 16)) * 0.4; tailUp = 0.9; wagSpeed = 8
                case .scratch:                                                // sits facing you, back paw kicks at her ear
                    scratching = true; happyEyes = true; tailUp = 0.9; wagSpeed = 10
                case .sneeze:
                    if it < 0.6 { headDY = 1.4 * it / 0.6; eyesClosed = true } else if it < 0.95 { headDY = -2.6; eyesClosed = true }
                case .shake:
                    shiver = CGFloat(sin(t * 30)) * 1.0; eyesClosed = true; osc = CGFloat(sin(t * 30 + 1)) * 0.5
                case .nap:
                    legH = 1.2; headDX = 1.0; headDY = -4.2; osc = breathe * 0.6; eyesClosed = true; tailUp = -0.4; wagSpeed = 0.8; wagAmp = 0.06
                case .dig:                                                    // butt up, head down, paws scrabbling
                    bodyRot = -0.3; rotPivot = NSPoint(x: 19, y: 2)
                    headDX = 2.8; headDY = -7.0; headRot = -0.3
                    frontKick = CGFloat(sin(t * 26)) * 1.3; tailUp = 0.85; wagSpeed = 16; wagAmp = 0.55
                }
            }
        }
        if d.fxNap { legH = 1.2; headDX = 1.0; headDY = -4.2; osc = breathe * 0.6; eyesClosed = true; tailUp = -0.4; wagSpeed = 0.8; wagAmp = 0.06 }
        if d.fxBark { tongue = true; tailUp = 1.1; wagSpeed = 14; wagAmp = 0.5; if t - lastBark < 0.35 { osc = 0.8 } }
        // play-date poses
        if d.fxTongue { tongue = true; tailUp = max(tailUp, 1.0); wagSpeed = max(wagSpeed, 14); wagAmp = max(wagAmp, 0.5) }
        if d.fxHappy { happyEyes = true; tailUp = 1.0; wagSpeed = 16; wagAmp = 0.55 }
        if d.fxBow { headDX = 2.0; headDY = -3.2; tailUp = 1.2; wagSpeed = 16; wagAmp = 0.55 }
        if d.fxLick { headDX = 1.6; osc = CGFloat(sin(t * 10)) * 0.9; tongue = true }
        if d.fxSad { tailUp = -0.6; wagSpeed = 1.5; wagAmp = 0.1; headDY = -3.4; if !eyesClosed { droopy = true; sadEyes = true } }

        if asleep && !d.wasAsleep { d.yawnUntil = t + 1.8 }
        if !asleep && d.wasAsleep && kind == nil && !walking { d.stretchUntil = t + 1.8 }
        d.wasAsleep = asleep
        let yawning = t < d.yawnUntil
        if yawning { legH = 5.2; headDY = 0.3; headDX = 0; eyesClosed = true; tongue = true; wagSpeed = 1; wagAmp = 0.1 }
        if t < d.stretchUntil { headDX = 2.0; headDY = -3.2; tailUp = 1.2; eyesClosed = true; legH = 5.2 }

        // ease every pose change instead of snapping
        let k = ease(0.2, ds)
        let tLeg = legH, tHX = headDX, tHY = headDY, tTail = tailUp
        d.sLegH += (tLeg - d.sLegH) * k; d.sHX += (tHX - d.sHX) * k; d.sHY += (tHY - d.sHY) * k
        d.sTail += (tTail - d.sTail) * k; d.sWagAmp += (wagAmp - d.sWagAmp) * k; d.sWagSpeed += (wagSpeed - d.sWagSpeed) * Double(k)
        let turnT: CGFloat = (d.front && !asleep && !yawning) ? 1 : 0
        d.turnS += (turnT - d.turnS) * ease(0.45, ds)
        d.dirS = d.dir
        d.settling = abs(headRot - d.sHeadRot) > 0.02 || abs(bodyRot - d.sBodyRot) > 0.02 || abs(tLeg - d.sLegH) > 0.05 || abs(tHY - d.sHY) > 0.05 || abs(tHX - d.sHX) > 0.05 || abs(tTail - d.sTail) > 0.03
            || abs(turnT - d.turnS) > 0.02 || (d.bowlA > 0.03 && kind != .feed)
        d.sHeadRot += (headRot - d.sHeadRot) * k
        d.sBodyRot += (bodyRot - d.sBodyRot) * (abs(bodyRot) > 2 || abs(d.sBodyRot) > 2 ? 1 : k)   // roll-over runs as is; small tilts ease
        bodyRot = d.sBodyRot
        legH = d.sLegH; headDX = d.sHX; headDY = d.sHY + osc; tailUp = d.sTail; wagAmp = d.sWagAmp
        if asleep && d.sLegH > 2.6 { eyesClosed = true }

        let headY = headDY + bodyBob
        d.earLag += ((d.lastHeadY - headY) / max(ds, 0.4) * 1.6 - d.earLag) * ease(0.35, ds)
        d.lastHeadY = headY

        ctx.saveGState()
        let ox = r.minX + d.x + shiver
        let oy = r.minY + 3 + min(d.jumpY, d.turnS > 0.5 ? 1.6 : 1.8) + d.depth * 2.4
        ctx.translateBy(x: ox + dogW / 2, y: oy)
        let sc = 1 - d.depth * 0.14                                           // smaller = further back
        if d.depth > 0.05 { ctx.setAlpha(1 - d.depth * 0.15) }
        ctx.scaleBy(x: (d.dir < 0 ? -1 : 1) * sc, y: sc)
        ctx.translateBy(x: -dogW / 2, y: 0)

        let L = d.look
        let fur = pet.sick ? L.sick : L.fur
        let hi = pet.sick ? (L.sick.blended(withFraction: 0.2, of: .white) ?? L.sick) : L.hi
        let blush = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.60, alpha: 0.55)
        /// curly coat puff: rendered once into a cached image, then just stamped (much cheaper than re-tracing curls)
        func fluff(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor, seed: Int, shine: Bool = true) {
            guard let (img, sz) = puffImage(w, h, c, shine ? hi : nil, seed) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: cx - sz.width / 2, y: cy - sz.height / 2, width: sz.width, height: sz.height))
        }
        func eye(_ ex: CGFloat, _ ey: CGFloat) {
            if happyEyes || eyesClosed {
                let e = NSBezierPath()
                if happyEyes { e.move(to: NSPoint(x: ex - 1.2, y: ey - 0.3)); e.line(to: NSPoint(x: ex, y: ey + 0.8)); e.line(to: NSPoint(x: ex + 1.2, y: ey - 0.3)) }
                else { e.move(to: NSPoint(x: ex - 1.2, y: ey)); e.curve(to: NSPoint(x: ex + 1.2, y: ey), controlPoint1: NSPoint(x: ex - 0.4, y: ey - 0.7), controlPoint2: NSPoint(x: ex + 0.4, y: ey - 0.7)) }
                e.lineWidth = 0.95; e.lineCapStyle = .round
                (L.fur.brightnessComponent < 0.4 ? NSColor(white: 0.70, alpha: 1) : INK).setStroke()   // visible on black fur too
                e.stroke()
            } else if droopy {                                                // hot & tired: heavy half-closed lids
                if L.fur.brightnessComponent < 0.4 { NSColor(white: 0.55, alpha: 0.55).setFill(); NSBezierPath(ovalIn: NSRect(x: ex - 1.7, y: ey - 1.7, width: 3.4, height: 3.6)).fill() }
                INK.setFill(); NSBezierPath(ovalIn: NSRect(x: ex - 1.25, y: ey - 1.3, width: 2.5, height: 2.8)).fill()
                NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: ex - 0.5, y: ey - 0.9, width: 0.8, height: 0.8)).fill()
                fur.setFill(); NSBezierPath(rect: NSRect(x: ex - 1.6, y: ey + 0.15, width: 3.2, height: 1.8)).fill()   // the lid
                // worried (sad): lid rises toward the nose side; hot/tired: flat heavy lid
                let lid = NSBezierPath(); lid.move(to: NSPoint(x: ex - 1.4, y: ey + (sadEyes ? -0.15 : 0.25)))
                lid.curve(to: NSPoint(x: ex + 1.4, y: ey + (sadEyes ? 0.95 : 0.25)), controlPoint1: NSPoint(x: ex - 0.5, y: ey - 0.1), controlPoint2: NSPoint(x: ex + 0.5, y: ey + (sadEyes ? 0.5 : -0.1)))
                lid.lineWidth = 0.75; lid.lineCapStyle = .round
                (L.fur.brightnessComponent < 0.4 ? NSColor(white: 0.75, alpha: 1) : INK).setStroke(); lid.stroke()
            } else {
                if L.fur.brightnessComponent < 0.4 { NSColor(white: 0.55, alpha: 0.55).setFill(); NSBezierPath(ovalIn: NSRect(x: ex - 1.7, y: ey - 1.7, width: 3.4, height: 3.6)).fill() }
                INK.setFill(); NSBezierPath(ovalIn: NSRect(x: ex - 1.25, y: ey - 1.3, width: 2.5, height: 2.8)).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: ex - 0.1, y: ey + 0.35, width: 0.95, height: 0.95)).fill()
                NSBezierPath(ovalIn: NSRect(x: ex - 0.75, y: ey - 0.8, width: 0.45, height: 0.45)).fill()
            }
        }
        func curlyEar(_ root: NSPoint, _ angle: CGFloat, _ mirror: Bool) {
            ctx.saveGState()
            ctx.translateBy(x: root.x, y: root.y); ctx.rotate(by: angle)
            let ep = NSBezierPath()
            for k in 0..<4 {
                let cy = -CGFloat(k) * 2.0, w: CGFloat = 4.6 - CGFloat(k) * 0.3
                let dx: CGFloat = (k % 2 == 0 ? 0 : 0.45) * (mirror ? -1 : 1)
                ep.appendOval(in: NSRect(x: -w / 2 + dx, y: cy - 1.7, width: w, height: 3.4))
            }
            L.dark.setFill(); ep.fill()
            ctx.restoreGState()
        }
        let tilt = CGFloat(sin(t * 0.7 + (d === dogs[1] ? 2 : 0))) * 0.12
        let outfit = pet.wearing
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
            case "flower":                                                    // flower crown
                for (i, dx) in [-3.2, 0.0, 3.2].enumerated() {
                    let fc = [NSColor.systemPink, NSColor.systemYellow, NSColor(srgbRed: 0.75, green: 0.6, blue: 1, alpha: 1)][i]
                    let cx = topX + CGFloat(dx), cy = topY + 1.4 + (i == 1 ? 0.6 : 0)
                    fc.setFill()
                    let pp = NSBezierPath()
                    for k in 0..<5 { let a = Double(k) * 1.2566; pp.appendOval(in: NSRect(x: cx + CGFloat(cos(a)) * 0.9 - 0.8, y: cy + CGFloat(sin(a)) * 0.9 - 0.8, width: 1.6, height: 1.6)) }
                    pp.fill()
                    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1)).fill()
                }
            case "beanie":                                                    // knit beanie with a pom
                let bc = NSColor(srgbRed: 0.25, green: 0.70, blue: 0.75, alpha: 1)
                bc.setFill()
                NSBezierPath(roundedRect: NSRect(x: topX - 4.6, y: topY - 1.2, width: 9.2, height: 5.2), xRadius: 4, yRadius: 3.5).fill()
                bc.blended(withFraction: 0.3, of: .black)!.setFill()
                NSBezierPath(roundedRect: NSRect(x: topX - 5, y: topY - 1.6, width: 10, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()
                NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: topX - 1.3, y: topY + 3.4, width: 2.6, height: 2.6)).fill()
            case "tiara":
                NSColor(white: 0.88, alpha: 1).setFill()
                let tp = NSBezierPath(); let cy = topY + 1.4
                tp.move(to: NSPoint(x: topX - 3.4, y: cy)); tp.line(to: NSPoint(x: topX - 2, y: cy + 1.6)); tp.line(to: NSPoint(x: topX - 0.8, y: cy + 0.8))
                tp.line(to: NSPoint(x: topX, y: cy + 2.6)); tp.line(to: NSPoint(x: topX + 0.8, y: cy + 0.8)); tp.line(to: NSPoint(x: topX + 2, y: cy + 1.6))
                tp.line(to: NSPoint(x: topX + 3.4, y: cy)); tp.close(); tp.fill()
                NSColor.systemPink.setFill(); NSBezierPath(ovalIn: NSRect(x: topX - 0.6, y: cy + 0.6, width: 1.2, height: 1.2)).fill()
            case "party":                                                     // birthday cone hat
                let hp = NSBezierPath(); let by = topY - 0.4
                hp.move(to: NSPoint(x: topX - 3.2, y: by)); hp.line(to: NSPoint(x: topX + 3.2, y: by)); hp.line(to: NSPoint(x: topX + 0.4, y: by + 7)); hp.close()
                NSColor(srgbRed: 0.35, green: 0.65, blue: 1, alpha: 1).setFill(); hp.fill()
                NSColor.systemYellow.setFill()
                NSBezierPath(rect: NSRect(x: topX - 2.2, y: by + 2, width: 4.2, height: 0.9)).fill()
                NSColor.systemPink.setFill(); NSBezierPath(ovalIn: NSRect(x: topX - 0.8, y: by + 6.4, width: 2.4, height: 2.4)).fill()
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
            (L.fur.brightnessComponent < 0.4 ? NSColor(srgbRed: 0.55, green: 0.45, blue: 0.32, alpha: 0.8) : NSColor(srgbRed: 0.30, green: 0.22, blue: 0.16, alpha: 0.75)).setFill()
            let dp = NSBezierPath()
            for (dx, dy) in [(-0.3, 0.1), (0.15, -0.2), (0.3, 0.2), (-0.1, -0.25)] as [(CGFloat, CGFloat)] {
                dp.appendOval(in: NSRect(x: cx + dx * w - 0.9, y: cy + dy * h - 0.6, width: 1.8, height: 1.2))
            }
            dp.fill()
        }
        let tongueC = NSColor(srgbRed: 0.98, green: 0.47, blue: 0.56, alpha: 1)

        func body(_ front: Bool) {
        if front {
            // ---- facing you ----
            let cx: CGFloat = dogW / 2, by = 0.2 + bodyBob * 0.4
            fluff(cx, by + 6.2 + breathe * 0.4, 14.5, 9.0, fur, seed: 1)
            dirtSpots(cx, by + 6, 14, 8)
            if outfit == "scarf" {
                NSColor(srgbRed: 0.85, green: 0.22, blue: 0.25, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: cx - 6, y: by + 9.2, width: 12, height: 2.6), xRadius: 1.3, yRadius: 1.3).fill()
                NSBezierPath(roundedRect: NSRect(x: cx + 2.2, y: by + 5.4, width: 2.4, height: 4.4), xRadius: 1, yRadius: 1).fill()
            } else if outfit == "bandana" {
                let bp = NSBezierPath(); bp.move(to: NSPoint(x: cx - 5.6, y: by + 10.6)); bp.line(to: NSPoint(x: cx + 5.6, y: by + 10.6)); bp.line(to: NSPoint(x: cx, y: by + 5.2)); bp.close()
                NSColor(srgbRed: 0.25, green: 0.45, blue: 0.95, alpha: 1).setFill(); bp.fill()
                NSColor.white.setFill()
                for (dx, dy) in [(-2.5, 9.4), (2.2, 9.2), (0.0, 7.4)] as [(CGFloat, CGFloat)] { NSBezierPath(ovalIn: NSRect(x: cx + dx - 0.4, y: by + dy - 0.4, width: 0.8, height: 0.8)).fill() }
            } else if outfit == "pearls" {
                NSColor(white: 0.96, alpha: 1).setFill()
                for k in 0..<7 {
                    let u = CGFloat(k) / 6 - 0.5
                    NSBezierPath(ovalIn: NSRect(x: cx + u * 10.5 - 0.8, y: by + 9.8 - (1 - 4 * u * u) * 1.8 - 0.8, width: 1.6, height: 1.6)).fill()
                }
            }
            if scratching { fluff(cx - 5.6, by + 3.6, 6.2, 5.2, fur.blended(withFraction: 0.18, of: .white) ?? fur, seed: 12, shine: false) }   // the haunch the scratching leg comes from
            else { fluff(cx - 3.9, by + 1.9, 4.8, 3.6, hi, seed: 2) }
            if pawRaise <= 0.02 { fluff(cx + 3.9, by + 1.9, 4.8, 3.6, hi, seed: 4) }
            ctx.saveGState()
            ctx.translateBy(x: cx, y: by + 13.2 + headDY * 0.5)
            ctx.rotate(by: kind == .pat ? CGFloat(sin(t * 6)) * 0.08 : (scratching ? 0.34 + CGFloat(sin(t * 24)) * 0.05 : tilt))
            curlyEar(NSPoint(x: -5.2, y: 1.6), 0.18 - d.earLag * 0.2, true)
            curlyEar(NSPoint(x: 5.2, y: 1.6), -0.18 + d.earLag * 0.2, false)
            fluff(0, 0.6, 12.2, 10.6, fur, seed: 5)
            fluff(0, 6.2, 7.8, 5.0, hi, seed: 9)
            blush.setFill()
            NSBezierPath(ovalIn: NSRect(x: -5.6, y: -2.6, width: 2.6, height: 1.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 3.0, y: -2.6, width: 2.6, height: 1.5)).fill()
            eye(-2.6, 1.0); eye(2.6, 1.0)
            headwear(topX: 0, topY: 6.4, eyes: [NSPoint(x: -2.6, y: 1.0), NSPoint(x: 2.6, y: 1.0)])
            L.cream.setFill(); NSBezierPath(roundedRect: NSRect(x: -2.6, y: -3.9, width: 5.2, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
            INK.setFill(); NSBezierPath(ovalIn: NSRect(x: -1.0, y: -1.5, width: 2.0, height: 1.5)).fill()
            if tongue {
                let tl: CGFloat = panting ? 2.8 + CGFloat(abs(sin(t * 10))) * 1.2 : 2.3
                tongueC.setFill(); NSBezierPath(ovalIn: NSRect(x: -0.9, y: -3.1 - tl + CGFloat(sin(t * 9)) * 0.3, width: 1.9, height: tl)).fill()
            }
            if kind == .mail {
                NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: -3.2, y: -7.2, width: 6.4, height: 4.2)).fill()
                let v = NSBezierPath(); v.move(to: NSPoint(x: -3.2, y: -3.0)); v.line(to: NSPoint(x: 0, y: -5.3)); v.line(to: NSPoint(x: 3.2, y: -3.0))
                v.lineWidth = 0.6; NSColor(white: 0.5, alpha: 1).setStroke(); v.stroke()
            }
            ctx.restoreGState()
            if scratching {                                                   // back paw up, scratching behind the ear
                let k = CGFloat(sin(t * 24))
                let px = cx - 9.6 + k * 0.6, py = by + 11.5 + k * 1.2
                let lp = NSBezierPath(); lp.move(to: NSPoint(x: cx - 6.2, y: by + 3.2)); lp.line(to: NSPoint(x: px + 1.2, y: py - 1.5))
                let thigh = fur.blended(withFraction: 0.18, of: .white) ?? fur
                lp.lineWidth = 3.8; lp.lineCapStyle = .round; thigh.setStroke(); lp.stroke()
                fluff(px, py, 4.2, 3.6, hi, seed: 6)
                let ml = NSBezierPath()                                       // scratch-scratch motion lines
                for j in 0..<3 { let a = CGFloat(j) * 0.7 + 2.0; ml.move(to: NSPoint(x: px + cos(a) * 3.4, y: py + sin(a) * 3.4)); ml.line(to: NSPoint(x: px + cos(a) * 5.4, y: py + sin(a) * 5.4)) }
                ml.lineWidth = 0.8; ml.lineCapStyle = .round; NSColor(white: 1, alpha: 0.9).setStroke(); ml.stroke()
            }
            if pawRaise > 0.02 {                                              // high five! paw up beside her face, in front
                let px = cx + 4.5 + pawRaise * 4.5, py = by + 2 + pawRaise * 10.5
                let lp = NSBezierPath(); lp.move(to: NSPoint(x: cx + 4, y: by + 5)); lp.line(to: NSPoint(x: px, y: py))
                lp.lineWidth = 3.4; lp.lineCapStyle = .round; fur.setStroke(); lp.stroke()
                fluff(px, py, 4.6, 4.0, hi, seed: 4)
            }
        } else {
            // ---- side view (chibi: big head, short fluffy legs) ----
            let bodyY = 1.0 + max(0, min(1, (legH - 1.2) / 4.0)) * 2.6 + bodyBob
            let rotating = abs(bodyRot) > 0.001
            if rotating {
                ctx.saveGState()
                ctx.translateBy(x: rotPivot.x, y: rotPivot.y); ctx.rotate(by: bodyRot); ctx.translateBy(x: -rotPivot.x, y: -rotPivot.y)
            }
            func leg(_ hipX: CGFloat, _ angle: CGFloat, _ color: NSColor, seed: Int, lift: CGFloat = 0) {
                if legH < 2 { fluff(hipX, 1.6, 4.0, 2.6, color, seed: seed, shine: false); return }
                let fx = hipX + sin(angle) * 3.4, fy: CGFloat = 1.9 + lift
                let p = NSBezierPath(); p.move(to: NSPoint(x: hipX, y: bodyY + 1.2)); p.line(to: NSPoint(x: fx, y: fy))
                p.lineWidth = 3.8; p.lineCapStyle = .round; color.setStroke(); p.stroke()
                fluff((hipX + fx) / 2, (bodyY + fy) / 2 + 0.4, 3.6, 3.2, color, seed: seed, shine: false)
                fluff(fx, fy, 4.4, 3.2, color, seed: seed + 1, shine: false)
            }
            let farC = fur.blended(withFraction: 0.28, of: .black) ?? fur
            leg(7.5, swing * 0.7, farC, seed: 11, lift: bodyRot < -0.01 ? -(rotPivot.x - 7.5) * sin(-bodyRot) : 0)
            leg(16.5, -swing * 0.7 - frontKick, farC, seed: 13)
            let wag = CGFloat(sin(d.wagPhase)) * wagAmp
            let tb = NSPoint(x: 5, y: bodyY + 5.2), ang = tailUp + wag
            let tip = NSPoint(x: tb.x - 3.2 * cos(ang), y: tb.y + 3.8 * sin(ang))
            let tp = NSBezierPath(); tp.move(to: tb); tp.line(to: tip); tp.lineWidth = 2.2; tp.lineCapStyle = .round
            fur.setStroke(); tp.stroke()
            fluff(tip.x, tip.y, 4.6, 4.6, fur, seed: 3)
            fluff(11.5, bodyY + 4.2 + (legH < 2 ? breathe * 0.5 : 0), 15.5, 8.6, fur, seed: 1)
            dirtSpots(11.5, bodyY + 4.2, 15, 8)
            if outfit == "scarf" {
                NSColor(srgbRed: 0.85, green: 0.22, blue: 0.25, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 15.6, y: bodyY + 5.0, width: 3.2, height: 6.2), xRadius: 1.4, yRadius: 1.4).fill()
            } else if outfit == "bandana" {
                let bp = NSBezierPath(); bp.move(to: NSPoint(x: 15.2, y: bodyY + 10.4)); bp.line(to: NSPoint(x: 19.4, y: bodyY + 10.4)); bp.line(to: NSPoint(x: 18.6, y: bodyY + 5.2)); bp.close()
                NSColor(srgbRed: 0.25, green: 0.45, blue: 0.95, alpha: 1).setFill(); bp.fill()
            } else if outfit == "pearls" {
                NSColor(white: 0.96, alpha: 1).setFill()
                for k in 0..<4 { NSBezierPath(ovalIn: NSRect(x: 16.8 + CGFloat(k) * 0.5, y: bodyY + 10.2 - CGFloat(k) * 1.5, width: 1.6, height: 1.6)).fill() }
            }
            let nearC = fur.blended(withFraction: 0.12, of: .white) ?? fur
            func reach(_ hipX: CGFloat) -> CGFloat {                          // tipped forward → stretch back legs down to the ground
                bodyRot < -0.01 ? -(rotPivot.x - hipX) * sin(-bodyRot) : 0
            }
            leg(6.5, -swing * 0.7 + backKick, nearC, seed: 17, lift: backLift + reach(6.5))
            leg(15.5, swing * 0.7 + frontKick, nearC, seed: 19)
            let hc = NSPoint(x: 20.5 + headDX, y: bodyY + 10.4 + headDY)
            ctx.saveGState()
            ctx.translateBy(x: hc.x, y: hc.y)
            ctx.rotate(by: (walking ? 0 : tilt * 0.6) + d.sHeadRot)
            fluff(0, 0, 11.4, 10.4, fur, seed: 5)
            fluff(-0.8, 5.2, 7.4, 4.8, hi, seed: 9)
            blush.setFill(); NSBezierPath(ovalIn: NSRect(x: 0.8, y: -2.6, width: 2.6, height: 1.5)).fill()
            L.cream.setFill(); NSBezierPath(roundedRect: NSRect(x: 2.4, y: -3.4, width: 5.0, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
            INK.setFill(); NSBezierPath(ovalIn: NSRect(x: 6.0, y: -1.8, width: 1.9, height: 1.6)).fill()
            if tongue {
                let tl: CGFloat = panting ? 3.0 + CGFloat(abs(sin(t * 10))) * 1.3 : 2.5
                tongueC.setFill(); NSBezierPath(ovalIn: NSRect(x: 3.9, y: -2.4 - tl + CGFloat(sin(t * 9)) * 0.3, width: 2.1, height: tl)).fill()
            }
            eye(2.2, 1.2)
            headwear(topX: -0.8, topY: 5.4, eyes: [NSPoint(x: 2.2, y: 1.2)])
            curlyEar(NSPoint(x: -2.4, y: 2.6), -0.22 + d.earLag * 0.3 + (asleep ? 0.35 : 0), false)
            if d.boneUntil > t, kind == nil, !asleep, d.idle != .nap, !d.fxNap, !(duo?.bone == true && inDuo(d)) { drawBone(at: NSPoint(x: 5.4, y: -4.4), w: 7) }
            ctx.restoreGState()
            if rotating { ctx.restoreGState() }
        }
        }
        // side <-> front: a quick cross-fade (each view composited whole, so no see-through seams)
        let fa = d.turnS
        if fa < 0.03 { body(false) }
        else if fa > 0.97 { body(true) }
        else {
            for (isFront, alpha) in [(false, 1 - fa), (true, fa)] {
                ctx.saveGState(); ctx.setAlpha(alpha); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                body(isFront)
                ctx.endTransparencyLayer(); ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }
}

// MARK: - pet row (after tapping the dog)

final class PetStatusChip: Chip {
    private var pet: Pet { Pet.selected }
    override init() { super.init(); setWidth(190) }
    required init?(coder: NSCoder) { fatalError() }

    override func drawContent(_ r: NSRect) {
        pet.update()
        let top = NSMutableAttributedString(attributedString: attr("\(pet.name) · \(pet.moodWord)", 11, .semibold, pet.sick ? .systemOrange : .white))
        top.append(attr("  ⇄", 9, .bold, dimText))                         // tap to switch Candie / Dior
        top.draw(at: NSPoint(x: r.minX + 8, y: r.maxY - top.size().height - 1))
        // bond level + streak, right side of the top line
        let lv = attr("Lv\(pet.level)" + (pet.streak > 1 ? " 🔥\(pet.streak)" : ""), 9, .bold, .systemPink)
        lv.draw(at: NSPoint(x: r.maxX - lv.size().width - 8, y: r.maxY - lv.size().height - 1.5))
        let lt = NSRect(x: r.maxX - lv.size().width - 8, y: r.maxY - 15.8, width: lv.size().width, height: 1.6)
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
        setWidth(30)   // icon only: the row also holds the yard + status, ~700 pt budget
    }
    required init?(coder: NSCoder) { fatalError() }
    override func drawContent(_ r: NSRect) {
        let i = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: 15)])
        i.draw(at: NSPoint(x: r.midX - i.size().width / 2, y: r.midY - i.size().height / 2))
    }
}
