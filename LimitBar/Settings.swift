import AppKit
import ServiceManagement

struct Config {
    var refreshSeconds: Double = 60
    var notifications: Bool = true

    static let path = appSupportDir + "/config.json"

    static func load() -> Config {
        var c = Config()
        if let obj = jsonObject(FileManager.default.contents(atPath: path)) {
            if let v = obj["refreshSeconds"] as? Double { c.refreshSeconds = max(30, v) }
            if let v = obj["notifications"] as? Bool { c.notifications = v }
        }
        return c
    }

    func save() {
        let obj: [String: Any] = ["refreshSeconds": refreshSeconds, "notifications": notifications]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: Config.path), options: .atomic)
            chmod(Config.path, 0o600)
        }
    }
}

/// User tapped "login" on the Claude chip: try a refresh, else open a real login.
func healClaudeTokenNow() {
    if !ClaudeAuth.ensureFresh(force: true) {
        DispatchQueue.main.async { runInTerminal("claude auth login") }
    }
}

// MARK: - Settings window

final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var refreshPopup: NSPopUpButton!
    private var notifBox: NSButton!
    private var loginBox: NSButton!
    private var statusLabels: [ProviderID: NSTextField] = [:]
    private weak var app: AppDelegate?

    init(app: AppDelegate) { self.app = app }

    func show() {
        if window == nil { build() }
        refreshStatus()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 8
        r.alignment = .firstBaseline
        return r
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "LimitBar"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let sv = NSStackView()
        sv.orientation = .vertical
        sv.alignment = .leading
        sv.spacing = 10
        sv.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        sv.addArrangedSubview(label("Accounts", size: 13, weight: .bold))
        for id in ProviderID.allCases {
            let s = label("…", size: 11.5, color: .secondaryLabelColor)
            statusLabels[id] = s
            let name = label(id.name, size: 12, weight: .semibold)
            name.widthAnchor.constraint(equalToConstant: 60).isActive = true
            sv.addArrangedSubview(row([name, s]))
        }

        let note = label("Claude: read from the Claude Code keychain item. Codex: ~/.codex/auth.json. Tokens are only ever sent to their own provider.",
                         size: 10.5, color: .tertiaryLabelColor)
        note.preferredMaxLayoutWidth = 430
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        sv.addArrangedSubview(note)

        sv.addArrangedSubview(label("General", size: 13, weight: .bold))
        refreshPopup = NSPopUpButton()
        for (t, v) in [("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300)] {
            refreshPopup.addItem(withTitle: t)
            refreshPopup.lastItem?.tag = v
        }
        let rl = label("Refresh every", size: 12)
        sv.addArrangedSubview(row([rl, refreshPopup]))

        notifBox = NSButton(checkboxWithTitle: "Notify at 90% / limit reached and when a Hermes session finishes", target: nil, action: nil)
        sv.addArrangedSubview(notifBox)
        loginBox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
        sv.addArrangedSubview(loginBox)

        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        sv.addArrangedSubview(save)

        w.contentView = sv
        window = w
        loadValues()
    }

    private func loadValues() {
        guard let cfg = app?.config else { return }
        refreshPopup.selectItem(withTag: Int(cfg.refreshSeconds))
        if refreshPopup.selectedItem == nil { refreshPopup.selectItem(withTag: 60) }
        notifBox.state = cfg.notifications ? .on : .off
        loginBox.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
    }

    func refreshStatus() {
        for u in app?.usages ?? [] {
            let text: String
            switch u.state {
            case .ok: text = "✓ connected\(u.plan.isEmpty ? "" : " · \(u.plan)")"
            case .authExpired(let w): text = "⚠︎ \(w)"
            case .failed(let w): text = "offline (\(w))"
            case .loading: text = "loading…"
            }
            statusLabels[u.id]?.stringValue = text
        }
    }

    @objc private func saveTapped() {
        guard let app else { return }
        var cfg = app.config
        cfg.refreshSeconds = Double(refreshPopup.selectedTag())
        cfg.notifications = notifBox.state == .on
        cfg.save()
        setLaunchAtLogin(loginBox.state == .on)
        app.configUpdated()
        window?.close()
    }
}

// LaunchAgent (works for an ad-hoc signed bundle, unlike SMAppService)
let launchAgentPath = NSHomeDirectory() + "/Library/LaunchAgents/com.melvern.limitbar.plist"

func setLaunchAtLogin(_ on: Bool) {
    let fm = FileManager.default
    if on {
        guard !fm.fileExists(atPath: launchAgentPath) else { return }
        let plist: [String: Any] = [
            "Label": "com.melvern.limitbar",
            "ProgramArguments": ["/Applications/LimitBar.app/Contents/MacOS/LimitBar"],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: URL(fileURLWithPath: launchAgentPath))
        }
    } else {
        try? fm.removeItem(atPath: launchAgentPath)
    }
}
