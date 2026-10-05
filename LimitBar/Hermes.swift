import AppKit
import SQLite3

// Live view of Hermes: which sessions are WORKING right now, which just
// FINISHED and wait for you, across the default profile and every bot profile.
// Source of truth: each profile's state.db (read-only). A turn in flight holds a
// heartbeat lease in session_turn_leases whose expires_at keeps moving forward.

struct HermesSession {
    enum Status: Int { case working = 0, done, idle }
    var id: String
    var profile: String           // "default" or bot name
    var title: String
    var status: Status
    var activity: String          // short "what is it doing"
    var since: Date               // working: turn start · done/idle: last activity
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ReadOnlyDB {
    private var db: OpaquePointer?
    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else { sqlite3_close(db); return nil }
        sqlite3_busy_timeout(db, 200)
    }
    deinit { sqlite3_close(db) }

    func rows(_ sql: String, _ args: [Any] = []) -> [[Any?]] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            if let d = a as? Double { sqlite3_bind_double(st, Int32(i + 1), d) }
            else if let s = a as? String { sqlite3_bind_text(st, Int32(i + 1), s, -1, SQLITE_TRANSIENT) }
        }
        var out: [[Any?]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var r: [Any?] = []
            for c in 0..<sqlite3_column_count(st) {
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER, SQLITE_FLOAT: r.append(sqlite3_column_double(st, c))
                case SQLITE_TEXT: r.append(String(cString: sqlite3_column_text(st, c)))
                default: r.append(nil)
                }
            }
            out.append(r)
        }
        return out
    }
}

/// "tool running: vision_analyze" → "vision" ; "terminal command running (40s elapsed)" → "terminal 40s"
func shortActivity(_ raw: String?, lastTool: String?) -> String {
    let s = (raw ?? "").lowercased()
    if s.contains("stream") || s.contains("thinking") { return "writing…" }
    if s.hasPrefix("tool running:") {
        return prettyTool(String(s.dropFirst("tool running:".count)).trimmingCharacters(in: .whitespaces))
    }
    if s.contains("terminal") {
        if let r = s.range(of: #"\((\d+)s"#, options: .regularExpression) {
            let secs = s[r].dropFirst().dropLast()
            return "terminal \(secs)s"
        }
        return "terminal"
    }
    if s.contains("compress") { return "compact…" }
    if let t = lastTool, !t.isEmpty { return prettyTool(t) }
    return "thinking…"
}

private func prettyTool(_ t: String) -> String {
    let map = ["browser_exec": "browser", "mcp__browser_exec": "browser", "vision_analyze": "vision",
               "mcp__vision_analyze": "vision", "read_file": "reading", "mcp__read_file": "reading",
               "write_file": "writing file", "mcp__write_file": "writing file", "patch": "edit", "mcp__patch": "edit",
               "web_search": "search", "mcp__web_search": "search", "web_extract": "reading web",
               "delegate_task": "subagent", "mcp__delegate_task": "subagent", "terminal": "terminal",
               "mcp__terminal": "terminal", "search_files": "searching", "mcp__search_files": "searching"]
    if let m = map[t] { return m }
    return t.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "_", with: " ")
}

func hermesHome() -> String { NSHomeDirectory() + "/.hermes" }

func fetchHermesSessions() -> [HermesSession] {
    var dbs: [(String, String)] = [("default", hermesHome() + "/state.db")]
    if let names = try? FileManager.default.contentsOfDirectory(atPath: hermesHome() + "/profiles") {
        for n in names.sorted() where n != "default" {
            dbs.append((n, hermesHome() + "/profiles/\(n)/state.db"))
        }
    }
    let now = Date().timeIntervalSince1970
    var out: [HermesSession] = []
    for (profile, path) in dbs {
        guard let db = ReadOnlyDB(path: path) else { continue }
        // working = live turn lease
        let leases = db.rows("SELECT conversation_id, acquired_at FROM session_turn_leases WHERE expires_at > ?", [now])
        var working: [String: Double] = [:]
        for r in leases { if let id = r[0] as? String { working[id] = r[1] as? Double ?? now } }

        // candidates: top-level, visible, active in the last 12h.
        // Bots run as `--source tool` one-shots → only interesting while working.
        let isBot = profile != "default"
        let rows = db.rows("""
            SELECT s.id, COALESCE(s.title, s.display_name, ''), s.last_activity_at, s.last_activity_description,
                   (SELECT m.role || '|' || COALESCE(m.finish_reason,'') || '|' || COALESCE(m.tool_name,'')
                      FROM messages m WHERE m.session_id = s.id ORDER BY m.id DESC LIMIT 1),
                   (s.ended_at IS NULL), s.source
            FROM sessions s
            WHERE s.parent_session_id IS NULL AND s.archived = 0 AND s.hidden = 0
              AND s.source IN ('desktop','cli','tui','tool','telegram','whatsapp','discord')
              AND COALESCE(s.last_activity_at, s.started_at) > ?
            ORDER BY COALESCE(s.last_activity_at, s.started_at) DESC LIMIT 12
            """, [now - 12 * 3600])
        for r in rows {
            guard let id = r[0] as? String else { continue }
            var title = (r[1] as? String ?? "")
            let source = r[6] as? String ?? ""
            if title.hasPrefix("Reply with just") || title.hasPrefix("Reply OK") { continue }   // health pings
            if title.isEmpty || title == "Bot Chat" { title = isBot ? "@\(profile)" : "Untitled" }
            else if isBot { title = "@\(profile) · \(title)" }
            let last = r[2] as? Double ?? now
            let openTurn = (r[5] as? Double ?? 0) > 0.5 && now - last < 180
            let tail = (r[4] as? String ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let lastTool = tail.count > 2 ? tail[2] : nil
            if working[id] != nil || openTurn {
                let started = working[id] ?? last
                out.append(HermesSession(id: id, profile: profile, title: title, status: .working,
                                         activity: shortActivity(r[3] as? String, lastTool: lastTool),
                                         since: Date(timeIntervalSince1970: started)))
            } else if !isBot && source != "tool" {
                // a turn that ended with a final assistant answer in the last 30 min = waiting for you
                let endedWithAnswer = tail.first == "assistant" && tail.count > 1 && tail[1] == "stop"
                let recent = now - last < 30 * 60
                out.append(HermesSession(id: id, profile: profile, title: title,
                                         status: endedWithAnswer && recent ? .done : .idle,
                                         activity: endedWithAnswer && recent ? "done" : "idle",
                                         since: Date(timeIntervalSince1970: last)))
            }
        }
    }
    // working first (longest-running first), then done (newest first), then idle
    out.sort {
        if $0.status != $1.status { return $0.status.rawValue < $1.status.rawValue }
        return $0.status == .working ? $0.since < $1.since : $0.since > $1.since
    }
    return out
}

/// Open a session in the Hermes desktop app (hermes://open/<id> routes to the
/// session view). Bot sessions live in another profile → just bring Hermes forward.
func openInHermes(_ s: HermesSession?) {
    if let s, s.profile == "default", let url = URL(string: "hermes://open/\(s.id)") {
        NSWorkspace.shared.open(url)
        return
    }
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.nousresearch.hermes").first {
        app.activate()
    }
}
