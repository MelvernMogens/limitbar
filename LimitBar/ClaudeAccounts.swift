import AppKit

// Claude account switcher (Touch Bar + menu bar).
//
// Hermes and Claude Code share one Claude login (Keychain "Claude Code-credentials" +
// ~/.claude/.credentials.json). `~/.hermes/bin/claude-akun <name>` swaps that login for one of the
// saved accounts and keeps rotated tokens in sync. LimitBar never touches tokens here: it reads the
// non-secret index (~/.hermes/claude-akun.json: names + emails) and runs the script on a tap.

struct ClaudeAccount {
    let name: String; let email: String
    let loginExpires: Date?          // `claude login` hard-expires ~30 days after logging in
    var loginLeft: TimeInterval? { loginExpires?.timeIntervalSinceNow }
}

/// Short "login left" text: "28d", "2d 5h", "expired".
func loginLeftText(_ left: TimeInterval?) -> String? {
    guard let left else { return nil }
    if left <= 0 { return "login expired" }
    return left >= 86400 ? "\(Int(left / 86400))d" : fmtLeft(left)
}

final class ClaudeAccounts {
    static let script = NSHomeDirectory() + "/.hermes/bin/claude-akun"
    static let index = NSHomeDirectory() + "/.hermes/claude-akun.json"
    static let claudeJSON = NSHomeDirectory() + "/.claude.json"

    private(set) var accounts: [ClaudeAccount] = []
    private(set) var activeEmail: String?
    private(set) var switching: String?           // name being switched to
    private(set) var failed: String?              // name whose last switch failed (shown ~4 s)
    var onChange: (() -> Void)?

    var available: Bool { FileManager.default.isExecutableFile(atPath: Self.script) && accounts.count > 1 }
    func isActive(_ a: ClaudeAccount) -> Bool { a.email == activeEmail }

    /// Cheap: two small JSON reads, no subprocess. Called when the picker opens / menu opens.
    func reload() {
        if let obj = jsonObject(FileManager.default.contents(atPath: Self.index)),
           let list = obj["accounts"] as? [[String: Any]] {
            accounts = list.compactMap {
                guard let n = $0["name"] as? String, let e = $0["email"] as? String else { return nil }
                let ms = $0["loginExpires"] as? Double
                return ClaudeAccount(name: n, email: e, loginExpires: ms.map { Date(timeIntervalSince1970: $0 / 1000) })
            }
        }
        // the login Claude Code / Hermes actually use right now
        if let cj = jsonObject(FileManager.default.contents(atPath: Self.claudeJSON)),
           let oa = cj["oauthAccount"] as? [String: Any] {
            activeEmail = oa["emailAddress"] as? String
        }
    }

    /// `claude-akun sync`: files a fresh `claude login` into its account's slot (or a new slot for a new
    /// email), so re-logging in never needs a manual save. Runs only when the Claude row opens — no polling.
    private var syncing = false
    func sync(done: @escaping () -> Void) {
        guard !syncing, switching == nil, FileManager.default.isExecutableFile(atPath: Self.script) else { return }
        syncing = true
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Self.script)
            p.arguments = ["sync"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { p.waitUntilExit() }
            DispatchQueue.main.async { self.syncing = false; self.reload(); done() }
        }
    }

    /// Runs `claude-akun <name>` off the main thread. Taps while a switch runs are ignored.
    func switchTo(_ name: String, done: @escaping (Bool) -> Void) {
        guard switching == nil else { return }
        switching = name; failed = nil
        onChange?()
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Self.script)
            p.arguments = [name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ok = false
            if (try? p.run()) != nil { p.waitUntilExit(); ok = p.terminationStatus == 0 }
            NSLog("[LimitBar] claude account switch to %@: %@", name, ok ? "ok" : "FAILED")
            DispatchQueue.main.async {
                self.switching = nil
                if !ok { self.failed = name }
                self.reload()
                self.onChange?()
                done(ok)
                if !ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        if self.failed == name { self.failed = nil; self.onChange?() }
                    }
                }
            }
        }
    }
}

/// One account in the Claude row: dot + name on top, status below. Active = clay dot + border.
final class AccountChip: Chip {
    let account: ClaudeAccount
    weak var store: ClaudeAccounts?
    private var top = attr("", 11), bottom = attr("", 9)

    init(_ a: ClaudeAccount, _ s: ClaudeAccounts) {
        account = a; store = s
        super.init()
        relayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    func relayout() {
        guard let s = store else { return }
        let clay = ProviderID.claude.color
        let active = s.isActive(account)
        // login days left ride along; ≤3 days turns orange, expired turns red (a switch to it would fail)
        let left = account.loginLeft
        let days = loginLeftText(left)
        let status: (String, NSColor) =
            s.switching == account.name ? ("switching…", dimText)
            : s.failed == account.name ? ("failed · claude login", .systemRed)
            : (left ?? 1) <= 0 ? ("login expired", .systemRed)
            : (left ?? .infinity) < 3 * 86400 ? ("login \(days!) left", .systemOrange)
            : active ? ("in use" + (days.map { " · \($0)" } ?? ""), clay)
            : ("tap to switch" + (days.map { " · \($0)" } ?? ""), faintText)
        top = attr(account.name, 11, .semibold, active ? .white : NSColor(white: 0.85, alpha: 1))
        bottom = attr(status.0, 9, .medium, status.1)
        border = active ? clay.withAlphaComponent(0.55) : nil
        setWidth(21 + max(top.size().width, bottom.size().width) + 8)
    }

    override func drawContent(_ r: NSRect) {
        guard let s = store else { return }
        let active = s.isActive(account)
        let c = CGPoint(x: r.minX + 11, y: r.midY)
        let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7))
        if active {
            ProviderID.claude.color.setFill(); dot.fill()
        } else {
            faintText.setStroke(); dot.lineWidth = 1.2; dot.stroke()
        }
        drawTwoLines(top, bottom, x: r.minX + 21, in: r)
    }
}

/// "Account:" label at the start of the account group.
final class AccountPickHeader: Chip {
    private let a = attr("Account:", 11, .medium, dimText)
    override init() { super.init(); setWidth(a.size().width + 12) }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let s = a.size()
        a.draw(at: NSPoint(x: 6, y: bounds.midY - s.height / 2))
    }
}
