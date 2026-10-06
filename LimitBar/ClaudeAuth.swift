import Foundation

// Keeps the Claude subscription OAuth token alive without anyone running `claude`.
//
// Claude Code stores {accessToken (8h), refreshToken (single-use, rotates), ...} in the
// login keychain ("Claude Code-credentials") and Hermes mirrors it in ~/.claude/.credentials.json.
// We refresh ~45 min before expiry and commit the rotated pair to BOTH stores, under the same
// flock Hermes uses (~/.claude/.credentials.lock), adopting any token another process already
// rotated instead of spending the refresh token twice.
//
// Endpoint notes (from hermes agent/anthropic_credentials.py): platform.claude.com is the live
// host; it 429s User-Agents starting with "claude-code/" — use a plain UA + form encoding.

enum ClaudeAuth {
    static let service = "Claude Code-credentials"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static var filePath: String { NSHomeDirectory() + "/.claude/.credentials.json" }
    static var lockPath: String { NSHomeDirectory() + "/.claude/.credentials.lock" }
    private static var nextAttempt = Date.distantPast
    private(set) static var lastStatus = "idle"

    // MARK: stores

    static func readKeychain() -> [String: Any]? {
        guard let d = runProcess("/usr/bin/security", ["find-generic-password", "-s", service, "-w"]),
              let obj = jsonObject(d.trimmingNewline()) else { return nil }
        return obj
    }

    static func readFile() -> [String: Any]? { jsonObject(FileManager.default.contents(atPath: filePath)) }

    static func oauth(_ obj: [String: Any]?) -> [String: Any]? { obj?["claudeAiOauth"] as? [String: Any] }

    static func expiry(_ oa: [String: Any]?) -> Date {
        Date(timeIntervalSince1970: (oa?["expiresAt"] as? Double ?? 0) / 1000)
    }

    /// The freshest credential set across keychain + file (Claude Code may update only one).
    static func current() -> [String: Any]? {
        let k = oauth(readKeychain()), f = oauth(readFile())
        switch (k, f) {
        case let (k?, f?): return expiry(k) >= expiry(f) ? k : f
        default: return k ?? f
        }
    }

    // MARK: refresh

    /// Refresh when the token expires within `margin`. Returns true if a valid token exists afterwards.
    @discardableResult
    static func ensureFresh(margin: TimeInterval = 45 * 60, force: Bool = false) -> Bool {
        guard let start = current() else { lastStatus = "no credentials"; return false }
        if !force && expiry(start).timeIntervalSinceNow > margin { lastStatus = "valid"; return true }
        guard force || Date() >= nextAttempt else { return expiry(start) > Date() }

        return withLock {
            // re-read under the lock: someone (Claude Code / Hermes) may have rotated already
            guard let cur = current() else { return false }
            if !force && expiry(cur).timeIntervalSinceNow > margin {
                lastStatus = "adopted"; return true
            }
            guard let rt = cur["refreshToken"] as? String, !rt.isEmpty else {
                lastStatus = "no refresh token"; return false
            }
            guard let resp = post(refreshToken: rt), let access = resp["access_token"] as? String else {
                nextAttempt = Date().addingTimeInterval(10 * 60)
                NSLog("[LimitBar] claude refresh failed: %@ (retry in 10m)", lastStatus)
                return expiry(cur) > Date()
            }
            let newRT = resp["refresh_token"] as? String ?? rt
            let expMs = (Date().timeIntervalSince1970 + (resp["expires_in"] as? Double ?? 28800)) * 1000
            NSLog("[LimitBar] claude refresh response fields: %@", resp.keys.sorted().joined(separator: ","))
            var base = cur
            if let rtIn = resp["refresh_token_expires_in"] as? Double {
                base["refreshTokenExpiresAt"] = Int64((Date().timeIntervalSince1970 + rtIn) * 1000)
            }
            commit(base: base, access: access, refresh: newRT, expiresAtMs: expMs)
            lastStatus = "refreshed"
            NSLog("[LimitBar] claude token refreshed, valid until %@", "\(Date(timeIntervalSince1970: expMs / 1000))")
            return true
        }
    }

    private static func post(refreshToken: String) -> [String: Any]? {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
        }
        let body = "grant_type=refresh_token&refresh_token=\(enc(refreshToken))&client_id=\(clientID)"
        // body goes through stdin (`-d @-`) so the token never appears in the process list
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "--max-time", "20", "-X", "POST",
                       "-H", "Content-Type: application/x-www-form-urlencoded",
                       "-H", "User-Agent: axios/1.7.9", "--data-binary", "@-", tokenURL]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { lastStatus = "curl failed"; return nil }
        inPipe.fileHandleForWriting.write(Data(body.utf8))
        try? inPipe.fileHandleForWriting.close()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let obj = jsonObject(data)
        if obj?["access_token"] == nil {
            let err = (obj?["error"] as? [String: Any])?["type"] as? String ?? (obj?["error"] as? String) ?? "no response"
            lastStatus = err
            return nil
        }
        return obj
    }

    /// Write the rotated pair to the keychain (keeping scopes/plan/tier) and to the file.
    private static func commit(base: [String: Any], access: String, refresh: String, expiresAtMs: Double) {
        var oa = base
        oa["accessToken"] = access
        oa["refreshToken"] = refresh
        oa["expiresAt"] = Int64(expiresAtMs)

        // keychain: only if Claude Code keeps it there
        if var kc = readKeychain() {
            var koa = (kc["claudeAiOauth"] as? [String: Any]) ?? [:]
            for (k, v) in oa { koa[k] = v }
            kc["claudeAiOauth"] = koa
            if let data = try? JSONSerialization.data(withJSONObject: kc),
               let json = String(data: data, encoding: .utf8) {
                let esc = json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let account = NSUserName()
                let cmd = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -w \"\(esc)\"\n"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                p.arguments = ["-i"]
                let inPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil {
                    inPipe.fileHandleForWriting.write(Data(cmd.utf8))
                    try? inPipe.fileHandleForWriting.close()
                    p.waitUntilExit()
                }
            }
        }

        // file: keep whatever else is in it
        var file = readFile() ?? [:]
        var foa = (file["claudeAiOauth"] as? [String: Any]) ?? [:]
        for k in ["accessToken", "refreshToken", "expiresAt", "scopes"] { if let v = oa[k] { foa[k] = v } }
        file["claudeAiOauth"] = foa
        if let data = try? JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted]) {
            let tmp = filePath + ".limitbar-tmp"
            FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
            _ = rename(tmp, filePath)
        }
    }

    private static func withLock<T>(_ body: () -> T) -> T {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        // wait up to ~25s for Hermes / another refresher
        var waited = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 && waited < 250 { usleep(100_000); waited += 1 }
        defer { flock(fd, LOCK_UN) }
        return body()
    }
}
