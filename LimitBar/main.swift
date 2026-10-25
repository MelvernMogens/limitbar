import AppKit
import UserNotifications

// LimitBar v2 — Touch Bar cockpit for AI coding plans + Hermes.
//
//  overview : [GLM][Claude][Codex]  [Hermes now]  [cpu ram bat]     | control strip
//  detail   : [‹][logo plan][5h ▬▬|▬ pace][weekly ▬|▬▬ pace][extras]
//  sessions : [‹][● working …][✓ done …][· idle …]  (swipe, tap = open in Hermes)

enum Mode { case overview, detail(ProviderID), sessions, localPick }

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSMenuDelegate {
    static let version = "2.2"

    private let trayID = NSTouchBarItem.Identifier("com.melvern.limitbar.tray")
    private var touchBar: NSTouchBar?
    private var statusItem: NSStatusItem!
    private var settings: SettingsController?
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var sessionTimer: Timer?

    var config = Config.load()
    private(set) var usages: [ProviderUsage] = ProviderID.allCases.map { ProviderUsage(id: $0) }
    private(set) var sessions: [HermesSession] = []
    private var mode: Mode = .overview
    private var lastAlert: [String: AlertLevel] = [:]
    private var lastDoneSeen: Set<String> = []
    private var fetching = false

    // reused views
    private lazy var providerChips: [ProviderID: ProviderChip] = Dictionary(uniqueKeysWithValues:
        ProviderID.allCases.map { id in (id, ProviderChip(ProviderUsage(id: id))) })
    private let hermesChip = HermesChip()
    private let backChip = BackChip()
    private let headerChip = HeaderChip()
    private let sessionWin = WindowChip()
    private let weeklyWin = WindowChip()
    private let extrasChip = ExtrasChip()
    private let strip = SessionsStrip()
    private let statsChip = StatsChip()
    private let localChip = LocalAIChip()
    private let localAI = LocalAI()
    private let localHeader = LocalPickHeader()
    private var modelChips: [String: LocalModelChip] = [:]
    private let sampler = StatsSampler()
    private var statsTimer: Timer?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        DFR.setShowsCloseBox(false)
        setupStatusItem()
        setupTray()
        wireTaps()
        present()
        reloadControlStrip()
        // first reload can race the modal bar and login items (Pock etc.) — repeat once things settle
        for d in [2.0, 8.0, 20.0] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { reloadControlStrip() } }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        settings = SettingsController(app: self)
        // test hook: `notifyutil`-style mode switch so the bar can be verified without touching it
        DistributedNotificationCenter.default().addObserver(forName: .init("com.melvern.limitbar.mode"), object: nil, queue: .main) { [weak self] n in
            guard let self, let s = n.object as? String else { return }
            if s == "sessions" { self.mode = .sessions }
            else if s.hasPrefix("detail."), let p = ProviderID(rawValue: String(s.dropFirst(7))) { self.mode = .detail(p) }
            else { self.mode = .overview }
            self.rebuildBar()
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.melvern.limitbar.localai"), object: nil, queue: .main) { [weak self] n in
            // object: "on:<model-id>" | "off" | "pick" (test hook + lets Hermes flip the switch)
            guard let self else { return }
            let s = n.object as? String ?? "pick"
            if s.hasPrefix("on:") { self.localAI.start(String(s.dropFirst(3))) }
            else if s == "off" { self.localAI.stop() }
            else { self.localChipTapped() }
        }
        startTimers()
        refreshUsage()
        refreshSessions()
        localAI.poll()
        NSLog("[LimitBar] launched v%@ pid %d", AppDelegate.version, ProcessInfo.processInfo.processIdentifier)
    }

    private func startTimers() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: config.refreshSeconds, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshSessions()
            self?.localAI.poll()
        }
        // 1s tick only repaints (countdowns, heartbeat) — no I/O
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.statsChip.stats = self.sampler.sample()
        }
        _ = sampler.sample()
        [refreshTimer, sessionTimer, tickTimer, statsTimer].forEach { $0?.tolerance = 0.3 }
    }

    func configUpdated() {
        config = Config.load()
        startTimers()
        refreshUsage()
    }

    @objc private func didWake() {
        refreshUsage()
        refreshSessions()
        present()
        // after sleep the right control strip can come back empty — re-render it once the bar is up
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { reloadControlStrip() }
    }

    // MARK: touch bar plumbing

    private func setupTray() {
        let item = NSCustomTouchBarItem(identifier: trayID)
        let b = NSButton(title: "", target: self, action: #selector(trayTapped))
        b.image = trayImage()
        b.bezelColor = NSColor(white: 0.16, alpha: 1)
        item.view = b
        (NSTouchBarItem.self as AnyObject).perform(NSSelectorFromString("addSystemTrayItem:"), with: item)
        DFR.setControlStripPresence(trayID, true)
    }

    private func trayImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            for (i, id) in ProviderID.allCases.enumerated() {
                id.color.setFill()
                let h: CGFloat = [10, 14, 8][i]
                NSBezierPath(roundedRect: NSRect(x: 2 + CGFloat(i) * 5.5, y: 2, width: 3.5, height: h), xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        return img
    }

    @objc private func trayTapped() {
        mode = .overview
        rebuildBar()
        present()
        reloadControlStrip()
    }

    @objc private func appChanged() { present() }

    private func present() {
        DFR.setShowsCloseBox(false)
        if touchBar == nil {
            let tb = NSTouchBar()
            tb.delegate = self
            touchBar = tb
            rebuildBar()
        }
        presentSystemModalStrip(touchBar!, identifier: trayID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { hideCloseButton() }
    }

    private func id(_ s: String) -> NSTouchBarItem.Identifier { .init("com.melvern.limitbar.\(s)") }

    private func rebuildBar() {
        guard let tb = touchBar else { return }
        switch mode {
        case .overview:
            tb.defaultItemIdentifiers = ProviderID.allCases.map { id("p.\($0.rawValue)") }
                + [.fixedSpaceSmall, id("hermes"), id("local"), id("stats")]
        case .detail(let pid):
            let hasWeek = usages.first { $0.id == pid }?.weekly != nil
            tb.defaultItemIdentifiers = [id("back"), id("header"), id("w.session")] + (hasWeek ? [id("w.weekly")] : []) + [id("extras")]
        case .sessions:
            tb.defaultItemIdentifiers = [id("back"), id("strip")]
        case .localPick:
            tb.defaultItemIdentifiers = [id("back"), id("lp.header")] + localAI.models.map { id("lm.\($0.id)") }
        }
        updateViews()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let key = identifier.rawValue.replacingOccurrences(of: "com.melvern.limitbar.", with: "")
        let view: NSView?
        switch key {
        case "hermes": view = hermesChip
        case "stats": view = statsChip
        case "local": view = localChip
        case "lp.header": view = localHeader
        case "back": view = backChip
        case "header": view = headerChip
        case "w.session": view = sessionWin
        case "w.weekly": view = weeklyWin
        case "extras": view = extrasChip
        case "strip": view = strip
        default:
            if key.hasPrefix("p."), let p = ProviderID(rawValue: String(key.dropFirst(2))) { view = providerChips[p] }
            else if key.hasPrefix("lm.") { view = modelChip(String(key.dropFirst(3))) }
            else { view = nil }
        }
        guard let v = view else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = v
        // if space ever runs short, the Hermes chip yields first — never the limits or stats
        item.visibilityPriority = key == "hermes" ? .low : .high
        return item
    }

    private func wireTaps() {
        for (pid, chip) in providerChips {
            chip.onTap = { [weak self] in
                guard let self else { return }
                if case .authExpired = self.usages.first(where: { $0.id == pid })?.state {
                    self.fixAuth(pid)
                    return
                }
                self.mode = .detail(pid)
                self.rebuildBar()
            }
        }
        hermesChip.onTap = { [weak self] in self?.mode = .sessions; self?.rebuildBar() }
        localChip.onTap = { [weak self] in self?.localChipTapped() }
        localAI.onChange = { [weak self] s in self?.localChip.aiState = s }
        statsChip.onTap = { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
        backChip.onTap = { [weak self] in self?.mode = .overview; self?.rebuildBar() }
        headerChip.onTap = { [weak self] in self?.refreshUsage() }
        extrasChip.onTap = { [weak self] in self?.refreshUsage() }
        sessionWin.onTap = { [weak self] in self?.cycleDetail() }
        weeklyWin.onTap = { [weak self] in self?.cycleDetail() }
    }

    /// On -> turn it off. Off / half-running -> show the model picker (never kills a half-running Ollama).
    private func localChipTapped() {
        switch localAI.state {
        case .on: localAI.stop()
        case .busy: break
        case .off, .partial:
            localAI.reloadModels()
            mode = .localPick
            rebuildBar()
        }
    }

    private func modelChip(_ mid: String) -> LocalModelChip? {
        if let c = modelChips[mid] { return c }
        guard let m = localAI.models.first(where: { $0.id == mid }) else { return nil }
        let c = LocalModelChip(m)
        c.onTap = { [weak self] in
            self?.localAI.start(mid)
            self?.mode = .overview
            self?.rebuildBar()
        }
        modelChips[mid] = c
        return c
    }

    private func cycleDetail() {
        guard case .detail(let cur) = mode else { return }
        let all = ProviderID.allCases
        mode = .detail(all[(all.firstIndex(of: cur)! + 1) % all.count])
        rebuildBar()
    }

    // MARK: data

    func refreshUsage() {
        guard !fetching else { return }
        fetching = true
        let key = config.glmKey
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let group = DispatchGroup()
            var results: [ProviderID: ProviderUsage] = [:]
            let lock = NSLock()
            for (pid, fn) in [(ProviderID.glm, { fetchGLM(key: key) }), (.claude, fetchClaude), (.codex, fetchCodex)] {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let r = fn()
                    lock.lock(); results[pid] = r; lock.unlock()
                    group.leave()
                }
            }
            group.wait()
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                self.usages = ProviderID.allCases.map { pid in
                    let new = results[pid] ?? ProviderUsage(id: pid)
                    // keep last good numbers on a transient network failure (< 15 min old)
                    if case .failed = new.state, let old = self.usages.first(where: { $0.id == pid }),
                       old.state == .ok, Date().timeIntervalSince(old.fetchedAt) < 900 { return old }
                    return new
                }
                for u in self.usages where u.state == .ok {
                    NSLog("[LimitBar] %@ OK 5h=%@ wk=%@ %@", u.id.name, u.session.map { pct($0.used) } ?? "-",
                          u.weekly.map { pct($0.used) } ?? "-", u.extras.joined(separator: ","))
                }
                for u in self.usages where u.state != .ok { NSLog("[LimitBar] %@ state=%@", u.id.name, "\(u.state)") }
                self.updateViews()
                self.checkAlerts()
                self.checkClaudeLogin()
            }
        }
    }

    func refreshSessions() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let s = fetchHermesSessions()
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = s.map { "\($0.id)\($0.status)\($0.activity)" } != self.sessions.map { "\($0.id)\($0.status)\($0.activity)" }
                self.notifyFinished(old: self.sessions, new: s)
                self.sessions = s
                if changed { self.updateViews() }
            }
        }
    }

    // MARK: render

    private func tick() {
        // countdowns + heartbeat; cheap repaint of what is on screen
        switch mode {
        case .overview:
            hermesChip.sessions = sessions
            if case .busy = localChip.aiState { localChip.needsDisplay = true }
            providerChips.values.forEach { $0.needsDisplay = true }
        case .detail: updateViews()
        case .sessions, .localPick: break
        }
        updateStatusIcon()
    }

    private func updateViews() {
        for u in usages { providerChips[u.id]?.usage = u }
        hermesChip.sessions = sessions
        if case .detail(let pid) = mode, let u = usages.first(where: { $0.id == pid }) {
            headerChip.usage = u
            let msg: String? = {
                switch u.state {
                case .authExpired(let w): return w
                case .failed(let w): return "error: \(w)"
                case .loading: return "loading…"
                case .ok: return nil
                }
            }()
            sessionWin.set(u.session, name: "5h", color: u.id.color, key: "\(pid.rawValue).5h", message: msg)
            weeklyWin.set(u.weekly, name: "week", color: u.id.color, key: "\(pid.rawValue).wk", message: msg)
            extrasChip.set(u.extras)
        }
        if case .sessions = mode {
            strip.maxWidth = 640
            strip.update(sessions) { [weak self] s in
                openInHermes(s)
                self?.mode = .overview
                self?.rebuildBar()
            }
        }
        updateStatusIcon()
    }

    // MARK: alerts

    private func checkAlerts() {
        guard config.notifications else { return }
        for u in usages where u.state == .ok {
            for w in [u.session, u.weekly].compactMap({ $0 }) {
                let key = "\(u.id.rawValue).\(w.label)"
                let level = AlertLevel(w.used)
                if level > (lastAlert[key] ?? .none) {
                    let name = w.label == "5h" ? "5-hour" : "weekly"
                    notify(level == .out ? "\(u.id.name) \(name) limit reached" : "\(u.id.name) \(name) limit at \(pct(w.used))",
                           "Resets in \(fmtLeft(w.secondsLeft)).")
                }
                lastAlert[key] = level
            }
        }
    }

    private var lastLoginWarn = Date.distantPast
    private func checkClaudeLogin() {
        guard config.notifications, Date().timeIntervalSince(lastLoginWarn) > 86400,
              let ms = ClaudeAuth.current()?["refreshTokenExpiresAt"] as? Double else { return }
        let left = Date(timeIntervalSince1970: ms / 1000).timeIntervalSinceNow
        if left < 3 * 86400 {
            lastLoginWarn = Date()
            notify("Claude login expires in \(fmtLeft(left))", "Run `claude auth login` once to renew for another 30 days.")
        }
    }

    private func notifyFinished(old: [HermesSession], new: [HermesSession]) {
        guard config.notifications, !old.isEmpty else { return }
        let wasWorking = Set(old.filter { $0.status == .working }.map { $0.id })
        for s in new where wasWorking.contains(s.id) && s.status != .working && !lastDoneSeen.contains(s.id + "\(s.since)") {
            lastDoneSeen.insert(s.id + "\(s.since)")
            notify("Hermes finished: \(s.title)", "Tap the session on the Touch Bar to open it.", id: s.id)
        }
    }

    private func notify(_ title: String, _ body: String, id: String? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if let id { c.userInfo = ["session": id] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        NSLog("[LimitBar] notify: %@", title)
    }

    private func fixAuth(_ pid: ProviderID) {
        switch pid {
        case .claude:
            DispatchQueue.global().async { healClaudeTokenNow(); DispatchQueue.main.async { self.refreshUsage() } }
        case .glm:
            settings?.show()
        case .codex:
            runInTerminal("codex login")
        }
    }

    // MARK: menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private var lastIconKey = ""
    private func updateStatusIcon() {
        guard let btn = statusItem?.button else { return }
        let ok = usages.filter { $0.state == .ok }
        let worst = ok.compactMap { u in [u.session, u.weekly].compactMap { $0 }.map { $0.used }.max() }.max() ?? 0
        let working = sessions.filter { $0.status == .working }.count
        let key = "\(Int(worst * 100))-\(working)-\(ok.count)"
        guard key != lastIconKey else { return }
        lastIconKey = key
        btn.image = menuBarImage(usages: usages)
        btn.title = working > 0 ? " \(working)" : ""
        btn.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    }

    /// Three tiny vertical gauges, template so they follow the menu bar appearance.
    private func menuBarImage(usages: [ProviderUsage]) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            for (i, id) in ProviderID.allCases.enumerated() {
                let u = usages.first { $0.id == id }
                let used = u.flatMap { $0.state == .ok ? [$0.session, $0.weekly].compactMap { $0 }.map { $0.used }.max() : nil } ?? 0
                let x = 1.5 + CGFloat(i) * 5
                let track = NSRect(x: x, y: 2, width: 3.5, height: 12)
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1.2, yRadius: 1.2).fill()
                // level shows REMAINING headroom (full = lots left)
                let left = max(0.08, 1 - used)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: 3.5, height: 12 * CGFloat(left)), xRadius: 1.2, yRadius: 1.2).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: "LimitBar \(AppDelegate.version)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        for u in usages {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = menuLine(u)
            if case .authExpired = u.state {
                item.action = #selector(menuFixAuth(_:))
                item.target = self
                item.representedObject = u.id.rawValue
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let hs = NSMenuItem(title: "Hermes", action: nil, keyEquivalent: "")
        hs.isEnabled = false
        menu.addItem(hs)
        if sessions.isEmpty {
            let e = NSMenuItem(title: "   no active sessions", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        for s in sessions.prefix(8) {
            let mark = s.status == .working ? "●" : (s.status == .done ? "✓" : "·")
            let tail: String = {
                switch s.status {
                case .working: return "\(s.activity) · \(fmtElapsed(s.since))"
                case .done: return "done \(fmtAgo(Date().timeIntervalSince(s.since)))"
                case .idle: return "idle \(fmtAgo(Date().timeIntervalSince(s.since)))"
                }
            }()
            let it = NSMenuItem(title: "\(mark)  \(s.title)  —  \(tail)", action: #selector(menuOpenSession(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s.id
            menu.addItem(it)
        }
        menu.addItem(.separator())
        switch localAI.state {
        case .off:
            localAI.reloadModels()
            for m in localAI.models {
                let it = NSMenuItem(title: "Start local AI: \(m.label)  (\(m.ram))", action: #selector(menuStartLocal(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = m.id
                menu.addItem(it)
            }
        case .on(let model, let mem):
            menu.addItem(withTitle: "Local AI: \(model) on (\(mem)) — turn off", action: #selector(menuStopLocal), keyEquivalent: "").target = self
        case .busy(let w):
            let it = NSMenuItem(title: "Local AI: \(w)…", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        case .partial:
            menu.addItem(withTitle: "Local AI: half-running — reset", action: #selector(menuStopLocal), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LimitBar", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func menuLine(_ u: ProviderUsage) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let f = NSFont.menuFont(ofSize: 13)
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        m.append(NSAttributedString(string: "●  ", attributes: [.font: f, .foregroundColor: u.id.color.blended(withFraction: 0.15, of: .black) ?? u.id.color]))
        m.append(NSAttributedString(string: u.id.name, attributes: [.font: NSFont.menuFont(ofSize: 13).bold()]))
        if !u.plan.isEmpty { m.append(NSAttributedString(string: " \(u.plan)", attributes: [.font: f, .foregroundColor: NSColor.secondaryLabelColor])) }
        switch u.state {
        case .ok:
            for w in [u.session, u.weekly].compactMap({ $0 }) {
                m.append(NSAttributedString(string: "   \(w.label) \(pct(w.used)) ↻\(fmtLeft(w.secondsLeft))",
                                            attributes: [.font: mono, .foregroundColor: severityColor(w.used) ?? NSColor.labelColor]))
            }
        case .authExpired(let why):
            m.append(NSAttributedString(string: "   ⚠︎ \(why) — click to fix", attributes: [.font: f, .foregroundColor: NSColor.systemOrange]))
        case .failed(let why):
            m.append(NSAttributedString(string: "   offline (\(why))", attributes: [.font: f, .foregroundColor: NSColor.secondaryLabelColor]))
        case .loading:
            m.append(NSAttributedString(string: "   loading…", attributes: [.font: f, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return m
    }

    @objc private func menuOpenSession(_ sender: NSMenuItem) {
        openInHermes(sessions.first { $0.id == sender.representedObject as? String })
    }
    @objc private func menuFixAuth(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let p = ProviderID(rawValue: raw) { fixAuth(p) }
    }
    @objc private func menuStartLocal(_ sender: NSMenuItem) { if let mid = sender.representedObject as? String { localAI.start(mid) } }
    @objc private func menuStopLocal() { localAI.stop() }
    @objc private func openSettings() { settings?.show() }
    @objc private func refreshNow() { refreshUsage(); refreshSessions() }

    @objc private func quit() {
        if let tb = touchBar { dismissSystemModal(tb) }
        DFR.setControlStripPresence(trayID, false)
        reloadControlStrip()
        NSApp.terminate(nil)
    }
}

extension NSFont {
    func bold() -> NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}

func runInTerminal(_ cmd: String) {
    let script = "tell application \"Terminal\" to do script \"\(cmd)\"\ntell application \"Terminal\" to activate"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
}

// MARK: - main

// test hook: `LimitBar --refresh-claude-now` rotates the token once and exits
if CommandLine.arguments.contains("--refresh-claude-now") {
    let ok = ClaudeAuth.ensureFresh(force: true)
    print("refresh:", ok, ClaudeAuth.lastStatus, "valid until", ClaudeAuth.expiry(ClaudeAuth.current()))
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
