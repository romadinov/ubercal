import Foundation

/// Reads the OWA (client Microsoft 365) calendar from Outlook on the web, through the *same* signed-in
/// agent-browser session that Jinnie uses (`jinnie-outlook`, profile in Jinnie's Application Support). The
/// tenant allows no client but Outlook and caps publishing/sharing at busy-only, so this is the one way to
/// see real event detail: it reads the calendar you see as yourself in the approved app.
///
/// Read-only by construction — it only opens URLs, snapshots and evals; it never clicks or types, so it can't
/// send, change or delete anything. For the same reason RSVP and editing aren't offered for these events.
struct OutlookReader: Sendable {
    static let session = "jinnie-outlook"

    enum ReaderError: Error, LocalizedError {
        case notInstalled
        case needsLogin
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "agent-browser isn't installed (Jinnie uses it to read Outlook)."
            case .needsLogin: "Outlook sign-in expired — sign in again from the gear menu."
            case .failed(let m): m
            }
        }
    }

    /// One calendar event as parsed from Outlook's accessibility labels. Sendable so it can cross actors.
    struct Event: Sendable, Hashable {
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var isTeams: Bool
        var tentative: Bool
    }

    var executable: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        executable = ["/opt/homebrew/bin/agent-browser", "/usr/local/bin/agent-browser", "\(home)/.local/bin/agent-browser"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "agent-browser"
    }

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: OutlookReader().executable) }

    /// Jinnie's persistent Chrome profile — the one already signed in to OWA. Sharing it is the whole point:
    /// no second sign-in, no duplicate MFA. (agent-browser warns and ignores --profile if the daemon is already
    /// running, which is fine: the running daemon already holds this profile.)
    static var profileDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jinnie/outlook-browser").path
    }

    // MARK: Browser plumbing (mirrors Jinnie's OutlookReader)

    @discardableResult
    func browser(_ args: [String], timeout: TimeInterval = 90) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["--session", Self.session, "--profile", Self.profileDirectory] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        // A file, not a pipe: the first call starts agent-browser's daemon, which would keep a pipe open forever.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ubercal-ab-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: file) else { throw ReaderError.failed("Couldn't start agent-browser.") }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: file) }
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        p.waitUntilExit()
        timer.cancel()
        if p.terminationReason == .uncaughtSignal { throw ReaderError.failed("agent-browser timed out: \(args.first ?? "")") }
        return String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
    }

    /// Opens a page and waits for it to settle. Opening Outlook bounces through login.microsoftonline.com
    /// for *silent* SSO, so landing there briefly is normal — only a sign-in that persists past the poll
    /// window (≈12s) counts as `.needsLogin`. Returns as soon as an Outlook page is reached.
    func open(_ url: String) throws {
        try browser(["open", url])
        for _ in 0..<10 {
            try browser(["wait", "1200"])
            let u = try browser(["get", "url"])
            if u.contains("outlook.office.com") || u.contains("outlook.office365.com") || u.contains("outlook.cloud.microsoft") {
                return
            }
        }
        let final = try browser(["get", "url"])
        if final.contains("login.microsoftonline.com") || final.contains("login.live.com") {
            throw ReaderError.needsLogin
        }
    }

    /// True if the shared session can reach the mailbox without a sign-in.
    func isSignedIn() -> Bool {
        (try? open("https://outlook.office.com/calendar/view/month")) != nil
    }

    /// Opens a visible window so the user can sign in (MFA, "stay signed in"). Shared with Jinnie, so signing
    /// in here re-authenticates both.
    func beginLogin() throws {
        _ = try? browser(["close"])
        try browser(["--headed", "open", "https://outlook.office.com/mail/"])
    }

    // MARK: Reading events

    private static let weekday = #"(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)"#

    /// Calendar events in the month grid plus the current week. Outlook on the web ignores dates in calendar
    /// URLs, so this reads the two views it will show and dedupes — enough for Ubercal's agenda and month grid.
    func events() throws -> [Event] {
        var raw: [String] = []
        var seen = Set<String>()
        for view in ["month", "week"] {
            try open("https://outlook.office.com/calendar/view/\(view)")
            let snap = try browser(["snapshot"])
            for line in snap.split(separator: "\n") where line.contains("- button \"") {
                guard let text = Self.quoted(String(line)), !text.hasPrefix("Go to") else { continue }
                if seen.insert(text).inserted { raw.append(text) }
            }
        }
        // Outlook shows times in the mailbox's time zone; the calendar labels its own clock. The gap from now is
        // the shift to undo so every event reads as an absolute instant (correct whatever this Mac's zone is).
        let shift = (try? browser(["eval", "document.querySelector('[aria-label^=\"calendar view, current time\"]')?.getAttribute('aria-label')||''"]))
            .flatMap { Self.calendarShift($0) } ?? 0
        try? open("https://outlook.office.com/mail/")   // leave the shared session on mail, as Jinnie expects it

        var out: [Event] = []
        var keys = Set<String>()
        for label in raw {
            guard let e = Self.parse(label, shift: shift) else { continue }
            if keys.insert("\(e.title)|\(e.start.timeIntervalSince1970)").inserted { out.append(e) }
        }
        return out
    }

    // MARK: Parsing

    static func parse(_ label: String, shift: TimeInterval) -> Event? {
        let isTeams = label.contains("Microsoft Teams Meeting")
        let tentative = label.contains(", Tentative")

        // Timed: "Title, 11:00 AM to 12:00 PM, Monday, November 2, 2026, …"
        let timed = #"^(.*?), (\d{1,2}:\d{2} [AP]M) to (\d{1,2}:\d{2} [AP]M), \#(weekday), ([A-Z][a-z]+ \d{1,2}, \d{4})"#
        if let m = firstMatch(timed, in: label), m.count == 5 {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMMM d, yyyy h:mm a"
            guard let start = f.date(from: "\(m[4]) \(m[2])"), var end = f.date(from: "\(m[4]) \(m[3])") else { return nil }
            if end < start { end = end.addingTimeInterval(86400) }
            return Event(title: tidy(m[1]), start: start.addingTimeInterval(-shift), end: end.addingTimeInterval(-shift),
                         isAllDay: false, isTeams: isTeams, tentative: tentative)
        }

        // All-day: "Title, all day, Monday, November 2, 2026, …"
        let allDay = #"^(.*?), [Aa]ll day, \#(weekday), ([A-Z][a-z]+ \d{1,2}, \d{4})"#
        if let m = firstMatch(allDay, in: label), m.count == 3 {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMMM d, yyyy"
            guard let day = f.date(from: m[2]) else { return nil }
            let start = Calendar.current.startOfDay(for: day)
            return Event(title: tidy(m[1]), start: start, end: start.addingTimeInterval(86400),
                         isAllDay: true, isTeams: isTeams, tentative: tentative)
        }
        return nil
    }

    /// Seconds Outlook's displayed clock is ahead of this Mac ("…current time: Wed 1:39 PM" at 11:39 → +7200),
    /// rounded to 15 minutes; 0 if it can't be read.
    static func calendarShift(_ label: String, now: Date = Date()) -> TimeInterval? {
        guard let r = label.range(of: #"(\d{1,2}):(\d{2}) ?([AP]M)"#, options: .regularExpression) else { return nil }
        let parts = label[r].replacingOccurrences(of: " ", with: "")
        let digits = parts.dropLast(2).split(separator: ":").compactMap { Int($0) }
        guard digits.count == 2 else { return nil }
        var h = digits[0] % 12
        if parts.hasSuffix("PM") { h += 12 }
        let shown = h * 60 + digits[1]
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        var diff = shown - ((c.hour ?? 0) * 60 + (c.minute ?? 0))
        if diff > 12 * 60 { diff -= 24 * 60 }
        if diff < -12 * 60 { diff += 24 * 60 }
        return TimeInterval(Int((Double(diff) / 15).rounded()) * 15 * 60)
    }

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }

    static func quoted(_ line: String) -> String? {
        guard let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b else { return nil }
        return String(line[line.index(after: a)..<b])
    }

    /// Drops Outlook's invisible padding and collapses whitespace.
    static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{034f}", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
