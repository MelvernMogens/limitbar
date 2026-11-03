import AppKit

// MARK: - Model

enum ProviderID: String, CaseIterable {
    case glm, claude, codex

    var name: String {
        switch self { case .glm: return "GLM"; case .claude: return "Claude"; case .codex: return "Codex" }
    }
    var color: NSColor {
        switch self {
        case .glm: return NSColor(white: 0.96, alpha: 1)
        case .claude: return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)   // Anthropic clay
        case .codex: return NSColor(srgbRed: 0.55, green: 0.50, blue: 1.0, alpha: 1)
        }
    }
    var logoPath: String {
        switch self { case .glm: return ZHIPU_PATH; case .claude: return CLAUDE_PATH; case .codex: return OPENAI_PATH }
    }
}

struct UsageWindow {
    var label: String          // "5h", "wk"
    var used: Double           // 0...1
    var resetsAt: Date?
    var length: TimeInterval   // window length in seconds

    /// Fraction of the window already elapsed (0...1).
    var elapsed: Double? {
        guard let r = resetsAt else { return nil }
        let left = r.timeIntervalSinceNow
        return min(1, max(0, 1 - left / length))
    }
    var secondsLeft: TimeInterval? { resetsAt.map { max(0, $0.timeIntervalSinceNow) } }
}

enum FetchState: Equatable {
    case loading, ok, authExpired(String), failed(String)
}

struct ProviderUsage {
    var id: ProviderID
    var state: FetchState = .loading
    var plan: String = ""
    var session: UsageWindow?      // 5h
    var weekly: UsageWindow?
    var extras: [String] = []      // e.g. "MCP 796/4000"
    var fetchedAt: Date = .distantPast
}

// MARK: - helpers

func runProcess(_ path: String, _ args: [String], timeout: Int = 20) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data.isEmpty ? nil : data
}

func curl(_ args: [String], maxTime: Int = 15) -> Data? {
    runProcess("/usr/bin/curl", ["-s", "--http1.1", "--max-time", String(maxTime)] + args)
}

func jsonObject(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()
func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

let appSupportDir: String = {
    let d = NSHomeDirectory() + "/Library/Application Support/LimitBar"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}()

// MARK: - GLM (z.ai coding plan)

func fetchGLM(key: String) -> ProviderUsage {
    var u = ProviderUsage(id: .glm)
    guard !key.isEmpty else { u.state = .authExpired("no API key"); return u }
    guard let obj = jsonObject(curl(["-H", "Authorization: Bearer " + key,
                                     "-H", "Accept: application/json",
                                     "https://api.z.ai/api/monitor/usage/quota/limit"])),
          let data = obj["data"] as? [String: Any],
          let limits = data["limits"] as? [[String: Any]] else {
        u.state = .failed("no response"); return u
    }
    if let level = data["level"] as? String { u.plan = level.capitalized }
    for l in limits {
        let type = l["type"] as? String
        let unit = l["unit"] as? Int
        let pct = (l["percentage"] as? Double ?? 0) / 100
        let reset = (l["nextResetTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        if type == "TOKENS_LIMIT" && unit == 3 {
            u.session = UsageWindow(label: "5h", used: pct, resetsAt: reset, length: 5 * 3600)
        } else if type == "TOKENS_LIMIT" && unit == 6 {
            u.weekly = UsageWindow(label: "wk", used: pct, resetsAt: reset, length: 7 * 86400)
        } else if type == "TIME_LIMIT" {
            // monthly MCP tool-call quota (web search / reader / vision)
            if let cur = l["currentValue"] as? Int, let tot = l["usage"] as? Int {
                u.extras.append("MCP tools \(cur)/\(tot)")
            }
        }
    }
    u.state = u.session == nil ? .failed("no 5h window") : .ok
    u.fetchedAt = Date()
    return u
}

// MARK: - Claude (subscription OAuth)

func fetchClaude() -> ProviderUsage {
    // refresh ~45 min before expiry so the bar never shows "login"
    ClaudeAuth.ensureFresh()
    var u = ProviderUsage(id: .claude)
    guard let oa = ClaudeAuth.current(), let token = oa["accessToken"] as? String else {
        u.state = .authExpired("not logged in"); return u
    }
    switch oa["rateLimitTier"] as? String ?? "" {
    case let t where t.contains("20x"): u.plan = "Max 20x"
    case let t where t.contains("5x"): u.plan = "Max 5x"
    default: u.plan = (oa["subscriptionType"] as? String ?? "").capitalized
    }
    if ClaudeAuth.expiry(oa) < Date() { u.state = .authExpired("token expired"); return u }
    guard let obj = jsonObject(curl(["-H", "Authorization: Bearer " + token,
                                     "-H", "Accept: application/json",
                                     "-H", "anthropic-beta: oauth-2025-04-20",
                                     "-H", "User-Agent: claude-code/2.1.227",
                                     "https://api.anthropic.com/api/oauth/usage"])) else {
        u.state = .failed("no response"); return u
    }
    if let err = obj["error"] as? [String: Any] {
        let type = err["type"] as? String ?? "error"
        if type.contains("auth") {
            // server says the token is dead even though expiresAt looked fine → rotate now
            if ClaudeAuth.ensureFresh(force: true) { return fetchClaude() }
            u.state = .authExpired("token expired")
        } else {
            u.state = .failed(type)
        }
        return u
    }
    func window(_ key: String, _ label: String, _ len: TimeInterval) -> UsageWindow? {
        guard let w = obj[key] as? [String: Any], let util = w["utilization"] as? Double else { return nil }
        return UsageWindow(label: label, used: util / 100, resetsAt: parseISO(w["resets_at"] as? String), length: len)
    }
    u.session = window("five_hour", "5h", 5 * 3600)
    // A fresh window (no usage yet) comes back as five_hour: null, which is 0%, not a failure.
    // Treating it as failed left the bar stuck on the previous account's numbers after an account switch.
    if u.session == nil, obj.keys.contains("five_hour") { u.session = UsageWindow(label: "5h", used: 0, resetsAt: nil, length: 5 * 3600) }
    u.weekly = window("seven_day", "wk", 7 * 86400)
    if let extra = obj["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true,
       let used = extra["used_credits"] as? Double, let lim = extra["monthly_limit"] as? Double {
        u.extras.append(String(format: "extra $%.0f/$%.0f", used / 100, lim / 100))
    }
    if let exp = (oa["refreshTokenExpiresAt"] as? Double).map({ Date(timeIntervalSince1970: $0 / 1000) }) {
        u.extras.append("login valid \(fmtLeft(exp.timeIntervalSinceNow))")
    }
    u.state = u.session == nil ? .failed("no 5h window") : .ok
    u.fetchedAt = Date()
    return u
}

// MARK: - Codex (ChatGPT plan, wham/usage)

private let codexAuthPath = appSupportDir + "/codex-auth.json"
private let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"   // from the codex CLI binary

/// Prefer the codex CLI's own auth (kept fresh by codex itself), else our copy.
private func codexAuthFiles() -> [String] {
    [NSHomeDirectory() + "/.codex/auth.json", codexAuthPath]
}

private func codexToken() -> (token: String, path: String)? {
    for p in codexAuthFiles() {
        if let obj = jsonObject(FileManager.default.contents(atPath: p)),
           let toks = obj["tokens"] as? [String: Any], let t = toks["access_token"] as? String, !t.isEmpty {
            return (t, p)
        }
    }
    return nil
}

/// Refresh with the rotating refresh token and write BOTH tokens back.
private func codexRefresh(path: String) -> String? {
    guard var obj = jsonObject(FileManager.default.contents(atPath: path)),
          var toks = obj["tokens"] as? [String: Any],
          let rt = toks["refresh_token"] as? String,
          let body = try? JSONSerialization.data(withJSONObject: [
              "grant_type": "refresh_token", "refresh_token": rt,
              "client_id": codexClientID, "scope": "openid profile email offline_access"]),
          let resp = jsonObject(curl(["-X", "POST", "-H", "Content-Type: application/json",
                                      "-d", String(decoding: body, as: UTF8.self),
                                      "https://auth.openai.com/oauth/token"])),
          let access = resp["access_token"] as? String else {
        NSLog("[LimitBar] codex refresh failed"); return nil
    }
    toks["access_token"] = access
    if let r = resp["refresh_token"] as? String { toks["refresh_token"] = r }
    if let id = resp["id_token"] as? String { toks["id_token"] = id }
    obj["tokens"] = toks
    obj["last_refresh"] = isoPlain.string(from: Date())
    if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
        try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    NSLog("[LimitBar] codex token refreshed")
    return access
}

func fetchCodex() -> ProviderUsage {
    var u = ProviderUsage(id: .codex)
    guard let (token, path) = codexToken() else { u.state = .authExpired("login codex"); return u }
    func get(_ t: String) -> [String: Any]? {
        jsonObject(curl(["-H", "Authorization: Bearer " + t, "-H", "Accept: application/json",
                         "https://chatgpt.com/backend-api/wham/usage"]))
    }
    var obj = get(token)
    if let err = obj?["error"] as? [String: Any], (err["code"] as? String) == "token_expired" {
        obj = codexRefresh(path: path).flatMap(get)
    }
    guard let o = obj, let rl = o["rate_limit"] as? [String: Any] else {
        u.state = obj?["error"] != nil ? .authExpired("login codex") : .failed("no response"); return u
    }
    u.plan = (o["plan_type"] as? String ?? "").capitalized
    func window(_ key: String, _ label: String) -> UsageWindow? {
        guard let w = rl[key] as? [String: Any] else { return nil }
        let len = w["limit_window_seconds"] as? Double ?? (label == "5h" ? 18000 : 604800)
        return UsageWindow(label: label, used: (w["used_percent"] as? Double ?? 0) / 100,
                           resetsAt: (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
                           length: len)
    }
    u.session = window("primary_window", "5h")
    u.weekly = window("secondary_window", "wk")
    if let credits = o["credits"] as? [String: Any], (credits["has_credits"] as? Bool) == true,
       let bal = credits["balance"] as? String {
        u.extras.append("credits \(bal)")
    }
    u.state = u.session == nil ? .failed("no 5h window") : .ok
    u.fetchedAt = Date()
    return u
}

extension Data {
    func trimmingNewline() -> Data {
        var d = self
        while let last = d.last, last == 10 || last == 13 { d.removeLast() }
        return d
    }
}
