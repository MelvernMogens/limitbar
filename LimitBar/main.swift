import AppKit
import Foundation
import SQLite3

// LimitBar v1.1 — Touch Bar usage monitor + menu bar app + settings.
// GLM (z.ai) · CLAUDE (subscription OAuth) · CODEX (ChatGPT wham/usage).
// No brightness control (Touch Bar backlight needs Apple entitlements — removed).

// MARK: - DFR private API bridge

enum DFR {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

    static func setControlStripPresence(_ identifier: NSTouchBarItem.Identifier, _ present: Bool) {
        guard let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        typealias F = @convention(c) (CFString, Bool) -> Void
        unsafeBitCast(sym, to: F.self)(identifier.rawValue as CFString, present)
    }

    static func setShowsCloseBox(_ show: Bool) {
        guard let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        typealias F = @convention(c) (Bool) -> Void
        unsafeBitCast(sym, to: F.self)(show)
    }
}

func dismissSystemModal(_ touchBar: NSTouchBar) {
    let cls = NSTouchBar.self as AnyObject
    let newSel = NSSelectorFromString("dismissSystemModalTouchBar:")
    let oldSel = NSSelectorFromString("dismissSystemModalFunctionBar:")
    if cls.responds(to: newSel) { cls.perform(newSel, with: touchBar) }
    else if cls.responds(to: oldSel) { cls.perform(oldSel, with: touchBar) }
}

/// MTMR's control-strip-VISIBLE mode: 2-arg present, NO placement.
func presentSystemModalStrip(_ touchBar: NSTouchBar, identifier: NSTouchBarItem.Identifier) {
    let cls = NSTouchBar.self as AnyObject
    let newSel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    let oldSel = NSSelectorFromString("presentSystemModalFunctionBar:systemTrayItemIdentifier:")
    let sel = cls.responds(to: newSel) ? newSel : (cls.responds(to: oldSel) ? oldSel : nil)
    guard let sel else {
        NSLog("[LimitBar] ERR no present selector"); return
    }
    typealias Fn = @convention(c) (AnyObject, Selector, NSTouchBar, NSString) -> Void
    guard let m = class_getClassMethod(NSTouchBar.self, sel), let impl = Optional(method_getImplementation(m)) else {
        NSLog("[LimitBar] ERR method not found"); return
    }
    let fn = unsafeBitCast(impl, to: Fn.self)
    fn(NSTouchBar.self, sel, touchBar, identifier.rawValue as NSString)
}

/// Force the system to re-render the control strip (same trick Pock ships).
func reloadControlStrip() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-x", "ControlStrip"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

/// Hide the system close (X) button on the function row (macOS 26 style).
func hideCloseButton() {
    let bgClass = NSClassFromString("NSFunctionRowBackgroundColorView")
    var candidates: [NSView] = []
    if let fr = NSClassFromString("NSFunctionRow") as? NSObject.Type {
        for selName in ["_topLevelFunctionRowViews", "_topLevelViews"] {
            let sel = NSSelectorFromString(selName)
            if fr.responds(to: sel) {
                let raw = fr.perform(sel)?.takeUnretainedValue()
                if let views = raw as? [NSView] { candidates = views }
            }
        }
    }
    if candidates.isEmpty {
        for w in NSApp.windows {
            collectFunctionRowViews(from: w.contentView, into: &candidates, bgClass: bgClass)
        }
    }
    for v in candidates {
        guard object_getClass(v) === bgClass else { continue }
        for sv in v.subviews {
            guard let stack = sv as? NSStackView else { continue }
            for ssv in stack.subviews {
                if let btn = ssv as? NSButton {
                    btn.isHidden = true
                    NSLog("[LimitBar] close button hidden")
                    return
                }
            }
        }
    }
}

private func collectFunctionRowViews(from v: NSView?, into out: inout [NSView], bgClass: AnyClass?) {
    guard let v else { return }
    if let bg = bgClass, object_getClass(v) === bg { out.append(v) }
    for sv in v.subviews { collectFunctionRowViews(from: sv, into: &out, bgClass: bgClass) }
}

// MARK: - Model

struct ProviderLimit {
    var label: String
    var pct5h: Double
    var pctWeek: Double
    var reset5h: String
    var resetWeek: String
    var color: NSColor
    var updatedAt: Date
}

let colGLM = NSColor(white: 0.95, alpha: 1)
let colClaude = NSColor.systemOrange
let colGPT = NSColor(srgbRed: 0.52, green: 0.48, blue: 0.98, alpha: 1)

struct Config {
    var glmKey: String = ""
    var refreshSeconds: Double = 60

    static let path = NSHomeDirectory() + "/Library/Application Support/LimitBar/config.json"

    static func load() -> Config {
        var c = Config()
        // key precedence: config.json > ~/.hermes/.env
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let v = obj["glmKey"] as? String { c.glmKey = v }
            if let v = obj["refreshSeconds"] as? Double { c.refreshSeconds = v }
        }
        if c.glmKey.isEmpty {
            let envPath = NSHomeDirectory() + "/.hermes/.env"
            if let text = try? String(contentsOfFile: envPath, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let name = parts[0].trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "export ", with: "")
                    let val = parts[1].trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if name == "GLM_API_KEY" || name == "ZAI_API_KEY" { c.glmKey = val }
                }
            }
        }
        return c
    }

    func save() {
        var obj: [String: Any] = [:]
        obj["glmKey"] = glmKey.isEmpty ? nil : glmKey
        obj["refreshSeconds"] = refreshSeconds
        let trimmed = obj.compactMapValues { $0 }
        if let data = try? JSONSerialization.data(withJSONObject: trimmed, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: Config.path))
        }
    }
}

// MARK: - shared helpers

func fmtCountdown(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d\(h)h" }
    if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
    return "\(m)m"
}

let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain = ISO8601DateFormatter()

func parseISO(_ s: String) -> Date? {
    isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

func curlJSON(_ args: [String], maxTime: Int = 15) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "--http1.1", "--max-time", String(maxTime)] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data.isEmpty ? nil : data
}

@discardableResult
func subprocessRun(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/" + args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - GLM live

struct ZAIResponse: Codable {
    struct LimitEntry: Codable {
        let type: String?
        let unit: Int?
        let percentage: Double?
        let nextResetTime: Double?
    }
    struct Data: Codable { let limits: [LimitEntry]? }
    let data: Data?
}

func fetchZAI(key: String) -> ProviderLimit? {
    guard let data = curlJSON(["-H", "Authorization: Bearer " + key,
                               "-H", "Accept: application/json",
                               "https://api.z.ai/api/monitor/usage/quota/limit"]),
          let z = try? JSONDecoder().decode(ZAIResponse.self, from: data) else { return nil }
    var p5: Double?, pW: Double?, r5: Double?, rW: Double?
    for l in z.data?.limits ?? [] where l.type == "TOKENS_LIMIT" {
        if l.unit == 3 { p5 = (l.percentage ?? 0) / 100; r5 = l.nextResetTime }
        if l.unit == 6 { pW = (l.percentage ?? 0) / 100; rW = l.nextResetTime }
    }
    guard let pct5 = p5 else { return nil }
    let reset5 = r5 != nil ? fmtCountdown(msToDate(r5!).timeIntervalSinceNow) : "-"
    let resetW = rW != nil ? fmtCountdown(msToDate(rW!).timeIntervalSinceNow) : "-"
    NSLog("[LimitBar] zai OK 5h=%d%% %@ wk=%d%% %@",
          Int((pct5 * 100).rounded()), reset5,
          Int(((pW ?? 0) * 100).rounded()), resetW)
    return ProviderLimit(label: "GLM", pct5h: pct5, pctWeek: pW ?? 0,
                         reset5h: reset5, resetWeek: resetW,
                         color: colGLM, updatedAt: Date())
}

func msToDate(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000.0) }

// MARK: - Claude live

struct ClaudeOAuth: Codable {
    struct Oauth: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Double?
    }
    let claudeAiOauth: Oauth
}

struct ClaudeUsage: Codable {
    struct Window: Codable {
        let utilization: Double?
        let resets_at: String?
    }
    let five_hour: Window?
    let seven_day: Window?
}

func fetchClaude() -> ProviderLimit? {
    // token source precedence (Claude Code moved to keychain 2026-10-05):
    // 1. keychain "Claude Code-credentials"  2. legacy ~/.claude/.credentials.json
    var token: String? = nil
    let sec = subprocessRun(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"])
    if !sec.isEmpty, let data = sec.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let oa = obj["claudeAiOauth"] as? [String: Any],
       let t = oa["accessToken"] as? String, !t.isEmpty {
        token = t
    }
    var refreshToken: String? = nil
    if token != nil,
       let obj = try? JSONSerialization.jsonObject(with: sec.data(using: .utf8)!) as? [String: Any],
       let oa = obj["claudeAiOauth"] as? [String: Any],
       let rt = oa["refreshToken"] as? String, !rt.isEmpty {
        refreshToken = rt
    }
    if token == nil {
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        if let credData = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let oauth = try? JSONDecoder().decode(ClaudeOAuth.self, from: credData) {
            token = oauth.claudeAiOauth.accessToken
            refreshToken = oauth.claudeAiOauth.refreshToken
        }
    }
    guard let tok = token else {
        NSLog("[LimitBar] claude credentials missing (keychain + file)"); return nil
    }
    _ = refreshToken
    guard let data = curlJSON(["-H", "Authorization: Bearer " + tok,
                               "-H", "Accept: application/json",
                               "-H", "User-Agent: claude-code/2.1.227",
                               "https://api.anthropic.com/api/oauth/usage"]),
          let u = try? JSONDecoder().decode(ClaudeUsage.self, from: data),
          let fh = u.five_hour, let p5 = fh.utilization else {
        NSLog("[LimitBar] claude usage FAILED"); return nil
    }
    let pW = u.seven_day?.utilization ?? 0
    let r5 = fh.resets_at.flatMap(parseISO).map { fmtCountdown($0.timeIntervalSinceNow) } ?? "-"
    let rW = u.seven_day?.resets_at.flatMap(parseISO).map { fmtCountdown($0.timeIntervalSinceNow) } ?? "-"
    NSLog("[LimitBar] claude OK 5h=%.0f%% %@ wk=%.0f%% %@", p5, r5, pW, rW)
    return ProviderLimit(label: "CLAUDE", pct5h: p5 / 100, pctWeek: pW / 100,
                         reset5h: r5, resetWeek: rW,
                         color: colClaude, updatedAt: Date())
}

// MARK: - Claude token auto-refresh (rate-limit aware, 10-min backoff)

final class ClaudeTokenRefresher {
    static let shared = ClaudeTokenRefresher()
    private var lastAttempt: Date = .distantPast
    private let lock = NSLock()

    /// Returns new access token on success, nil otherwise.
    func refresh(refreshToken: String, tokenPath: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(lastAttempt) > 600 else { return nil }  // backoff
        lastAttempt = Date()

        let body = String(data: try! JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ]), encoding: .utf8)!

        for host in ["https://platform.claude.com/v1/oauth/token",
                     "https://console.anthropic.com/v1/oauth/token"] {
            guard let resp = curlJSON(["-X", "POST",
                                       "-H", "Content-Type: application/json",
                                       "-H", "User-Agent: claude-code/2.1.227",
                                       "-d", body, host]),
                  let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
                  let newTok = obj["access_token"] as? String else { continue }
            // merge back into credentials file, preserving other keys
            if let raw = try? Data(contentsOf: URL(fileURLWithPath: tokenPath)),
               var orig = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                var oa = orig["claudeAiOauth"] as? [String: Any] ?? [:]
                oa["accessToken"] = newTok
                if let nrt = obj["refresh_token"] as? String { oa["refreshToken"] = nrt }
                if let expIn = obj["expires_in"] as? Double {
                    oa["expiresAt"] = Int((Date().timeIntervalSince1970 + expIn) * 1000)
                }
                orig["claudeAiOauth"] = oa
                if let out = try? JSONSerialization.data(withJSONObject: orig, options: [.prettyPrinted, .sortedKeys]) {
                    try? out.write(to: URL(fileURLWithPath: tokenPath))
                }
            }
            NSLog("[LimitBar] claude token refreshed via %@", host)
            return newTok
        }
        NSLog("[LimitBar] claude refresh rate-limited — retry in 10 min")
        return nil
    }
}

// MARK: - CODEX live

struct CodexAuthFile: Codable {
    struct Tokens: Codable {
        let access_token: String
        let refresh_token: String?
    }
    let tokens: Tokens?
}

func codexAccessToken() -> String? {
    // our own copy first
    let own = NSHomeDirectory() + "/Library/Application Support/LimitBar/codex-auth.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: own)),
          let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
          let t = auth.tokens?.access_token else {
        // fall back to CodexBar's home if still present
        let dir = NSHomeDirectory() + "/Library/Application Support/CodexBar/managed-codex-homes"
        guard let en = FileManager.default.enumerator(atPath: dir) else { return nil }
        while let f = (en.nextObject() as? String) {
            guard f.hasSuffix("auth.json") else { continue }
            let path = dir + "/" + f
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let a = try? JSONDecoder().decode(CodexAuthFile.self, from: d) else { continue }
            if let t = a.tokens?.access_token { return t }
        }
        return nil
    }
    return t
}

/// Refresh the codex OAuth token via auth.openai.com (client_id from codex CLI binary).
/// Returns a valid access token, or nil if refresh failed.
func codexRefreshToken() -> String? {
    let own = NSHomeDirectory() + "/Library/Application Support/LimitBar/codex-auth.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: own)),
          let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
          let rt = auth.tokens?.refresh_token else { return nil }

    let body = String(data: try! JSONSerialization.data(withJSONObject: [
        "grant_type": "refresh_token",
        "refresh_token": rt,
        "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
        "scope": "openid profile email offline_access",
    ]), encoding: .utf8)!

    guard let resp = curlJSON(["-X", "POST",
                               "-H", "Content-Type: application/json",
                               "-d", body,
                               "https://auth.openai.com/oauth/token"]),
          let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
          let newTok = obj["access_token"] as? String else {
        NSLog("[LimitBar] codex refresh failed"); return nil
    }
    // save back
    if var orig = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        var toks = orig["tokens"] as? [String: Any] ?? [:]
        toks["access_token"] = newTok
        if let nrt = obj["refresh_token"] as? String { toks["refresh_token"] = nrt }
        orig["tokens"] = toks
        orig["last_refresh"] = "limitbar"
        if let out = try? JSONSerialization.data(withJSONObject: orig, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: own))
        }
    }
    NSLog("[LimitBar] codex token refreshed")
    return newTok
}

struct CodexUsage: Codable {
    struct Window: Codable {
        let used_percent: Double?
        let reset_at: Double?
        let reset_after_seconds: Double?
    }
    struct RateLimit: Codable {
        let primary_window: Window?
        let secondary_window: Window?
    }
    let rate_limit: RateLimit?
}

func fetchCodex() -> ProviderLimit? {
    var token = codexAccessToken()
    var data = token.flatMap { curlJSON(["-H", "Authorization: Bearer " + $0,
                                         "-H", "Accept: application/json",
                                         "https://chatgpt.com/backend-api/wham/usage"]) }
    // parse check: if body says token_expired, refresh once and retry
    if let d = data, let s = String(data: d, encoding: .utf8), s.contains("token_expired") {
        NSLog("[LimitBar] codex token expired — refreshing")
        if let newTok = codexRefreshToken() {
            token = newTok
            data = curlJSON(["-H", "Authorization: Bearer " + newTok,
                             "-H", "Accept: application/json",
                             "https://chatgpt.com/backend-api/wham/usage"])
        }
    }
    guard let tok = token, let d = data,
          let u = try? JSONDecoder().decode(CodexUsage.self, from: d),
          let pw = u.rate_limit?.primary_window else {
        NSLog("[LimitBar] codex usage FAILED"); return nil
    }
    let p5 = (pw.used_percent ?? 0) / 100
    let sw = u.rate_limit?.secondary_window
    let pW = (sw?.used_percent ?? 0) / 100
    let now = Date().timeIntervalSince1970
    let r5 = pw.reset_at.map { fmtCountdown($0 - now) } ?? "-"
    let rW = sw?.reset_at.map { fmtCountdown($0 - now) } ?? "-"
    NSLog("[LimitBar] codex OK 5h=%.0f%% %@ wk=%.0f%% %@", p5 * 100, r5, pW * 100, rW)
    return ProviderLimit(label: "CODEX", pct5h: p5, pctWeek: pW,
                         reset5h: r5, resetWeek: rW,
                         color: colGPT, updatedAt: Date())
}

// MARK: - Card view

final class CardView: NSView {
    var limit: ProviderLimit {
        didSet { rebuild() }
    }

    private var totalW: CGFloat = 200
    private var tag5hA: NSAttributedString!
    private var pct5hA: NSAttributedString!
    private var rst5hA: NSAttributedString!
    private var tagWkA: NSAttributedString!
    private var pctWkA: NSAttributedString!
    private var rstWkA: NSAttributedString!
    private var xLogo: CGFloat = 0
    private var xTag5h: CGFloat = 0
    private var xBar5h: CGFloat = 0
    private var xPct5h: CGFloat = 0
    private var xRst5h: CGFloat = 0
    private var xTagWk: CGFloat = 0
    private var xBarWk: CGFloat = 0
    private var xPctWk: CGFloat = 0
    private var xRstWk: CGFloat = 0
    private let barW: CGFloat = 54
    private let barH: CGFloat = 6
    private let gap: CGFloat = 8
    private let padX: CGFloat = 9
    private let logoW: CGFloat = 20

    init(limit: ProviderLimit) {
        self.limit = limit
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: totalW, height: 30) }
    override var fittingSize: NSSize { NSSize(width: totalW, height: 30) }

    private func rebuild() {
        let c = limit.color
        let dim = NSColor(white: 0.58, alpha: 1)
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let tagFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)

        tag5hA = NSAttributedString(string: "5h", attributes: [.font: tagFont, .foregroundColor: c.withAlphaComponent(0.75)])
        pct5hA = NSAttributedString(string: "\(Int((limit.pct5h * 100).rounded()))%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold), .foregroundColor: c])
        rst5hA = NSAttributedString(string: limit.reset5h, attributes: [.font: mono, .foregroundColor: dim])
        tagWkA = NSAttributedString(string: "wk", attributes: [.font: tagFont, .foregroundColor: c.withAlphaComponent(0.75)])
        pctWkA = NSAttributedString(string: "\(Int((limit.pctWeek * 100).rounded()))%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: c.withAlphaComponent(0.9)])
        rstWkA = NSAttributedString(string: limit.resetWeek, attributes: [.font: mono, .foregroundColor: dim])

        var x = padX
        xLogo = x; x += logoW + gap
        xTag5h = x; x += tag5hA.size().width + 3
        xBar5h = x; x += barW + 5
        xPct5h = x; x += pct5hA.size().width + 4
        xRst5h = x; x += rst5hA.size().width + gap + 4
        xTagWk = x; x += tagWkA.size().width + 3
        xBarWk = x; x += barW + 5
        xPctWk = x; x += pctWkA.size().width + 4
        xRstWk = x; x += rstWkA.size().width
        totalW = x + padX

        setFrameSize(NSSize(width: totalW, height: 30))
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    override func draw(_ dirtyRect: NSRect) {
        let content = NSRect(x: 0, y: 0, width: totalW, height: 30)
        let b = content.insetBy(dx: 1.5, dy: 3)
        NSBezierPath(roundedRect: b, xRadius: 5, yRadius: 5).setClip()
        NSColor(white: 0.10, alpha: 1).setFill()
        b.fill()
        let mid = b.midY

        drawLogo(cx: xLogo + logoW / 2, cy: mid, color: limit.color)

        tag5hA.draw(at: NSPoint(x: xTag5h, y: mid - tag5hA.size().height / 2))
        drawBar(x: xBar5h, pct: limit.pct5h, color: limit.color, midY: mid)
        pct5hA.draw(at: NSPoint(x: xPct5h, y: mid - pct5hA.size().height / 2))
        rst5hA.draw(at: NSPoint(x: xRst5h, y: mid - rst5hA.size().height / 2))
        tagWkA.draw(at: NSPoint(x: xTagWk, y: mid - tagWkA.size().height / 2))
        drawBar(x: xBarWk, pct: limit.pctWeek, color: limit.color.withAlphaComponent(0.6), midY: mid)
        pctWkA.draw(at: NSPoint(x: xPctWk, y: mid - pctWkA.size().height / 2))
        rstWkA.draw(at: NSPoint(x: xRstWk, y: mid - rstWkA.size().height / 2))
    }

    private func drawBar(x: CGFloat, pct: Double, color: NSColor, midY: CGFloat) {
        let track = NSRect(x: x, y: midY - barH / 2, width: barW, height: barH)
        NSColor(white: 0.28, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * pct, height: barH)
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }

    private func drawLogo(cx: CGFloat, cy: CGFloat, color: NSColor) {
        let pathD: String
        switch limit.label {
        case "GLM": pathD = ZHIPU_PATH
        case "CLAUDE": pathD = CLAUDE_PATH
        case "CODEX": pathD = OPENAI_PATH
        default: pathD = ZHIPU_PATH
        }
        let cgPath = TinySVGPath.parse(pathD)
        let box = cgPath.boundingBox
        let size: CGFloat = 18
        let scale = min(size / max(box.width, 1), size / max(box.height, 1))
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -box.midX, y: -box.midY)
        color.setFill()
        ctx.addPath(cgPath)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

// MARK: - Settings window

final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var keyField: NSTextField!
    private var refreshField: NSTextField!
    private var statusLabel: NSTLabel?
    private weak var app: AppDelegate?

    init(app: AppDelegate) {
        self.app = app
    }

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "LimitBar Settings"
        w.delegate = self
        let sv = NSStackView()
        sv.orientation = .vertical
        sv.alignment = .leading
        sv.spacing = 12
        sv.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = sv

        let title = NSTextField(labelWithString: "Provider Auth")
        title.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        sv.addArrangedSubview(title)

        // GLM key
        let keyRow = NSStackView()
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        let keyLabel = NSTextField(labelWithString: "GLM / z.ai API key:")
        keyLabel.font = NSFont.systemFont(ofSize: 12)
        keyField = NSSecureTextField()
        keyField.placeholderString = "from ~/.hermes/.env (GLM_API_KEY)"
        keyField.stringValue = app?.config.glmKey ?? ""
        keyField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        keyField.lineBreakMode = .byTruncatingMiddle
        keyRow.addArrangedSubview(keyLabel)
        keyRow.addArrangedSubview(keyField)

        // Claude info
        let claudeInfo = NSTextField(labelWithString: "CLAUDE: otomatis dari ~/.claude/.credentials.json (login Claude Code)")
        claudeInfo.font = NSFont.systemFont(ofSize: 11)
        claudeInfo.textColor = .secondaryLabelColor

        // Codex info
        let codexInfo = NSTextField(labelWithString: "CODEX: otomatis dari auth ChatGPT (disalin dari CodexBar)")
        codexInfo.font = NSFont.systemFont(ofSize: 11)
        codexInfo.textColor = .secondaryLabelColor

        // refresh interval
        let refreshRow = NSStackView()
        refreshRow.orientation = .horizontal
        refreshRow.spacing = 8
        let refreshLabel = NSTextField(labelWithString: "Refresh interval (seconds):")
        refreshLabel.font = NSFont.systemFont(ofSize: 12)
        refreshField = NSTextField()
        refreshField.stringValue = String(Int(app?.config.refreshSeconds ?? 60))
        refreshField.font = NSFont.systemFont(ofSize: 12)
        refreshField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        refreshRow.addArrangedSubview(refreshLabel)
        refreshRow.addArrangedSubview(refreshField)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"

        sv.addArrangedSubview(keyRow)
        sv.addArrangedSubview(claudeInfo)
        sv.addArrangedSubview(codexInfo)
        sv.addArrangedSubview(refreshRow)
        sv.addArrangedSubview(saveBtn)

        // constraints
        keyLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        keyField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        sv.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 20).isActive = true
        sv.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -20).isActive = true
        sv.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 20).isActive = true

        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    @objc private func save() {
        var cfg = app?.config ?? Config()
        let trimmed = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { cfg.glmKey = trimmed }
        if let secs = Double(refreshField.stringValue), secs >= 15 { cfg.refreshSeconds = secs }
        cfg.save()
        app?.configUpdated()
        window?.close()
    }
}

// tiny label helper (avoid custom class name clashes)
class NSTLabel: NSTextField {
    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Hermes sessions (state.db read-only)

struct HermesSession {
    var id: String
    var title: String
    var uptimeText: String
    var isLive: Bool   // true = turn in flight (ended_at NULL)
}

func fetchHermesSessions() -> [HermesSession] {
    let p = NSHomeDirectory() + "/.hermes/state.db"
    guard let con = try? SQLiteDatabase.open(path: p) else { return [] }
    let now = Date().timeIntervalSince1970
    // "running" = activity within 24h (sessions get ended_at set when a turn
    // finalizes, but the chat is still open/switchable — ended_at is NOT "closed")
    let rows = con.query("""
        SELECT id, COALESCE(title, display_name, id), started_at, last_activity_at,
               (ended_at IS NULL)
        FROM sessions
        WHERE hidden = 0 AND last_activity_at > ?
        ORDER BY last_activity_at DESC LIMIT 8
        """, args: [now - 24 * 3600])
    var out: [HermesSession] = []
    for r in rows {
        guard let id = r[0] as? String, let title = r[1] as? String,
              let la = r[3] as? Double else { continue }
        let st = r[2] as? Double ?? la
        let live = (r[4] as? Double ?? 0) > 0.5   // ended_at NULL = turn in flight
        let idle = max(0, now - la)
        let h = Int(idle) / 3600, m = (Int(idle) % 3600) / 60
        let agoText = h > 0 ? "\(h)h\(String(format: "%02d", m))m ago" : "\(m)m ago"
        let dur = max(0, la - st)
        let dh = Int(dur) / 3600, dm = (Int(dur) % 3600) / 60
        let durText = dh > 0 ? "\(dh)h\(String(format: "%02d", dm))m" : "\(dm)m"
        out.append(HermesSession(id: id, title: String(title.prefix(26)),
                                 uptimeText: live ? durText : agoText,
                                 isLive: live))
    }
    NSLog("[LimitBar] hermes sessions: %d active(24h)", out.count)
    return out
}

/// Minimal read-only SQLite via sqlite3 C API (no dependencies).
final class SQLiteDatabase {
    private var db: OpaquePointer?

    static func open(path: String) -> SQLiteDatabase? {
        var ptr: OpaquePointer?
        // read-only URI
        let uri = "file:" + path + "?mode=ro"
        guard sqlite3_open_v2(uri, &ptr, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(ptr)
            return nil
        }
        let db = SQLiteDatabase()
        db.db = ptr
        return db
    }
    deinit { sqlite3_close(db) }

    func query(_ sql: String, args: [Any]) -> [[Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            if let d = a as? Double {
                sqlite3_bind_double(stmt, Int32(i + 1), d)
            } else if let s = a as? String {
                sqlite3_bind_text(stmt, Int32(i + 1), s, -1, SQLITE_TRANSIENT)
            }
        }
        var rows: [[Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any] = []
            let n = sqlite3_column_count(stmt)
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_FLOAT: row.append(Double(sqlite3_column_double(stmt, c)))
                case SQLITE_INTEGER: row.append(Double(sqlite3_column_int64(stmt, c)))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(stmt, c)))
                default: row.append(NSNull())
                }
            }
            rows.append(row)
        }
        return rows
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Hermes sessions pill (tap to cycle running sessions)

final class SessionsPill: NSButton {
    var selectedID: String?

    var sessions: [HermesSession] = [] {
        didSet {
            // keep the user's selection stable across refreshes (by session id,
            // since sort order changes with activity) — fall back to same index
            if let sid = selectedID, let i = sessions.firstIndex(where: { $0.id == sid }) {
                idx = i
            } else if idx >= sessions.count {
                idx = 0
            } else {
                rebuild()
            }
        }
    }
    var idx = 0 {
        didSet {
            selectedID = idx < sessions.count ? sessions[idx].id : nil
            rebuild()
        }
    }

    private var totalW: CGFloat = 230
    private var titleA: NSAttributedString?
    private var upA: NSAttributedString?
    private let padX: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.frame = NSRect(x: 0, y: 0, width: 230, height: 30)
        isBordered = false
        bezelStyle = .texturedRounded
        action = #selector(cycleAction(_:))
        target = self
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func cycleAction(_ sender: Any?) {
        guard sessions.count > 1 else { return }
        idx = (idx + 1) % sessions.count
    }

    override var intrinsicContentSize: NSSize { NSSize(width: totalW, height: 30) }
    override var fittingSize: NSSize { NSSize(width: totalW, height: 30) }

    private func rebuild() {
        let accent = NSColor.controlAccentColor
        if sessions.isEmpty {
            titleA = NSAttributedString(string: "no hermes session", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(white: 0.45, alpha: 1)])
            upA = NSAttributedString(string: "", attributes: [:])
            totalW = 140
        } else {
            let s = sessions[idx]
            let dot = sessions.count > 1 ? "·\(idx+1)/\(sessions.count) " : ""
            titleA = NSAttributedString(string: dot + s.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: accent])
            upA = NSAttributedString(string: "⏱\(s.uptimeText)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: NSColor(white: 0.6, alpha: 1)])
            totalW = padX + 10 + (titleA?.size().width ?? 0) + 6 + (upA?.size().width ?? 0) + padX
        }
        setFrameSize(NSSize(width: totalW, height: 30))
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    override func draw(_ dirtyRect: NSRect) {
        // ensure attributed strings exist (draw can fire before any rebuild)
        if titleA == nil { rebuild() }
        guard let t = titleA else { return }
        let b = bounds.insetBy(dx: 1.5, dy: 3)
        if b.width < 4 { return }
        // highlight when pressed
        if isHighlighted {
            NSColor(white: 0.22, alpha: 1).setFill()
        }
        NSBezierPath(roundedRect: b, xRadius: 5, yRadius: 5).setClip()
        NSColor(white: 0.13, alpha: 1).setFill()
        b.fill()
        let mid = b.midY
        // status dot: green = live turn, grey = idle-but-recent
        let dotColor = sessions.isEmpty
            ? NSColor(white: 0.3, alpha: 1)
            : (sessions[idx].isLive ? NSColor.systemGreen.withAlphaComponent(0.9) : NSColor(white: 0.55, alpha: 1))
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: b.minX + 8, y: mid - 2.5, width: 5, height: 5)).fill()
        t.draw(at: NSPoint(x: b.minX + 18, y: mid - t.size().height / 2))
        if let upAttr = upA, !upAttr.string.isEmpty {
            upAttr.draw(at: NSPoint(x: b.maxX - 8 - upAttr.size().width, y: mid - upAttr.size().height / 2))
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    private let trayID = NSTouchBarItem.Identifier("com.melvern.limitbar.tray")
    private let cardID = NSTouchBarItem.Identifier("com.melvern.limitbar.card")
    private let nextID = NSTouchBarItem.Identifier("com.melvern.limitbar.next")
    private let sessID = NSTouchBarItem.Identifier("com.melvern.limitbar.sessions")

    private var touchBar: NSTouchBar?
    private var statusItem: NSStatusItem!
    private var settings: SettingsController?
    private var refreshTimer: Timer?

    private var data: [ProviderLimit] = [
        ProviderLimit(label: "GLM", pct5h: 0, pctWeek: 0, reset5h: "…", resetWeek: "…", color: colGLM, updatedAt: .distantPast),
        ProviderLimit(label: "CLAUDE", pct5h: 0, pctWeek: 0, reset5h: "…", resetWeek: "…", color: colClaude, updatedAt: .distantPast),
        ProviderLimit(label: "CODEX", pct5h: 0, pctWeek: 0, reset5h: "…", resetWeek: "…", color: colGPT, updatedAt: .distantPast),
    ]
    private var idx = 0
    var config = Config.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DFR.setShowsCloseBox(false)

        // menu bar icon (next to battery)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = statusBarIcon()
            btn.image?.isTemplate = true
            btn.toolTip = "LimitBar"
        }
        rebuildMenu()

        // touch bar
        let item = NSCustomTouchBarItem(identifier: trayID)
        let b = NSButton(title: "⚡︎", target: self, action: #selector(toggle))
        b.bezelColor = NSColor(white: 0.16, alpha: 1)
        b.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        item.view = b
        (NSTouchBarItem.self as AnyObject).perform(NSSelectorFromString("addSystemTrayItem:"), with: item)
        DFR.setControlStripPresence(trayID, true)

        present()
        reloadControlStrip()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        settings = SettingsController(app: self)
        startTimer()
        refresh()
        NSLog("[LimitBar] launched v1.1 · menubar + settings · %@", String(ProcessInfo.processInfo.processIdentifier))
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: config.refreshSeconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func configUpdated() {
        config = Config.load()
        startTimer()
        refresh()
    }

    private func statusBarIcon() -> NSImage? {
        // solid gauge icon (filled, template) — outline-only looked ghostly
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.black.setFill()
        // outer battery/gauge body
        let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 5.5, width: 13, height: 7), xRadius: 2, yRadius: 2)
        body.fill()
        // cap
        NSRect(x: 15, y: 7.5, width: 2, height: 3).fill()
        // cut inner track (transparent) then fill level
        NSColor.white.setFill()
        let inner = NSBezierPath(roundedRect: NSRect(x: 3, y: 7, width: 10, height: 4), xRadius: 1, yRadius: 1)
        inner.fill()
        NSColor.black.setFill()
        let lvl = max(data.first?.pct5h ?? 0, 0.15)
        NSRect(x: 3.5, y: 7.5, width: 9 * CGFloat(lvl), height: 3).fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "LimitBar v1.1", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(NSMenuItem.separator())

        for (i, d) in data.enumerated() {
            let m = NSMenuItem(title: "\(d.label)  5h \(Int(d.pct5h * 100))%  wk \(Int(d.pctWeek * 100))%", action: #selector(cardSelected(_:)), keyEquivalent: "")
            m.tag = i
            menu.addItem(m)
        }
        menu.addItem(NSMenuItem.separator())
        let q = NSMenuItem(title: "Quit LimitBar", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(q)
        statusItem.menu = menu
    }

    @objc private func cardSelected(_ sender: NSMenuItem) {
        idx = sender.tag
        redraw()
    }

    @objc private func openSettings() { settings?.show() }
    @objc private func refreshNow() { refresh() }

    @objc private func quit() {
        if let tb = touchBar { dismissSystemModal(tb) }
        DFR.setControlStripPresence(trayID, false)
        reloadControlStrip()
        NSApp.terminate(nil)
    }

    @objc private func appChanged() { present() }

    private var barVisible = true

    @objc private func toggle() {
        barVisible = true
        present()
        reloadControlStrip()
    }

    private func present() {
        DFR.setShowsCloseBox(false)
        if touchBar == nil {
            let tb = NSTouchBar()
            tb.delegate = self
            tb.defaultItemIdentifiers = [cardID, nextID, sessID]
            touchBar = tb
        }
        presentSystemModalStrip(touchBar!, identifier: trayID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { hideCloseButton() }
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var glm: ProviderLimit? = nil
            if !self.config.glmKey.isEmpty { glm = fetchZAI(key: self.config.glmKey) }
            let claude = fetchClaude()
            let codex = fetchCodex()
            var next: [ProviderLimit] = []
            next.append(glm ?? ProviderLimit(label: "GLM", pct5h: 0, pctWeek: 0, reset5h: "off", resetWeek: "off", color: colGLM, updatedAt: .distantPast))
            next.append(claude ?? ProviderLimit(label: "CLAUDE", pct5h: 0, pctWeek: 0, reset5h: "expired", resetWeek: "-", color: colClaude, updatedAt: .distantPast))
            next.append(codex ?? ProviderLimit(label: "CODEX", pct5h: 0, pctWeek: 0, reset5h: "off", resetWeek: "off", color: colGPT, updatedAt: .distantPast))
            DispatchQueue.main.async {
                self.data = next
                self.redraw()
                self.rebuildMenu()
                // refresh hermes sessions pill
                if let tb = self.touchBar,
                   let item = tb.item(forIdentifier: self.sessID) as? NSCustomTouchBarItem,
                   let pill = item.view as? SessionsPill {
                    pill.sessions = fetchHermesSessions()
                }
            }
        }
    }

    private func redraw() {
        guard !data.isEmpty else { return }
        if let tb = touchBar,
           let item = tb.item(forIdentifier: cardID) as? NSCustomTouchBarItem,
           let cv = item.view as? CardView {
            cv.limit = data[idx]
        }
    }

    @objc private func next() { guard !data.isEmpty else { return }; idx = (idx + 1) % data.count; redraw() }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case sessID:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = SessionsPill(frame: .zero)
            return item
        case nextID:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let b = NSButton(title: "›", target: self, action: #selector(next))
            b.bezelColor = NSColor(white: 0.16, alpha: 1)
            b.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            item.view = b
            return item
        case cardID:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = CardView(limit: data.isEmpty
                ? ProviderLimit(label: "…", pct5h: 0, pctWeek: 0, reset5h: "-", resetWeek: "-", color: colGLM, updatedAt: Date())
                : data[idx])
            return item
        default:
            return nil
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
