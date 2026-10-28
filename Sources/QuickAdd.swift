import Foundation
import FoundationModels
import Observation

struct DraftEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    var invitees: [InviteeChoice] = []
}

/// A name typed after "with", the matching contacts, and which one (if any) to invite.
struct InviteeChoice: Equatable {
    var query: String
    var options: [ContactSearch.Person]
    var selectedIndex: Int?
    var selected: ContactSearch.Person? { selectedIndex.map { options[$0] } }
}

/// Live preview uses the instant rule-based parser; once typing pauses, the on-device
/// Apple Intelligence model (if available) tidies the title and location — it copes with typos.
@MainActor @Observable
final class QuickAddModel {
    var text = "" { didSet { if text != oldValue { parse() } } }
    /// Work email domain, so "Nathan" prefers the colleague over a personal contact.
    var preferDomain: String?
    private(set) var draft: DraftEvent?
    private(set) var refining = false
    private var task: Task<Void, Never>?

    static var aiEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "useAI") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useAI") }
    }
    static var aiAvailable: Bool { SystemLanguageModel.default.isAvailable }

    private func parse() {
        task?.cancel()
        let input = text
        draft = RuleParser.parse(input).map(resolveInvitees)
        guard let base = draft, Self.aiEnabled, Self.aiAvailable else { refining = false; return }
        refining = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let refined = await AIParser.refine(input, base: base)
            guard !Task.isCancelled else { return }
            if let refined { draft = refined }
            refining = false
        }
    }

    func choose(_ index: Int, option: Int?) {
        guard draft?.invitees.indices.contains(index) == true else { return }
        draft?.invitees[index].selectedIndex = option
    }

    private func resolveInvitees(_ d: DraftEvent) -> DraftEvent {
        let names = RuleParser.people(in: text)
        let emails = RuleParser.emails(in: text)
        guard !names.isEmpty || !emails.isEmpty else { return d }
        if ContactSearch.undetermined {
            Task {
                if await ContactSearch.requestAccess() { parse() }
            }
        }
        var d = d
        d.invitees = names.map { name in
            let options = ContactSearch.search(name, preferDomain: preferDomain)
            return InviteeChoice(query: name, options: options, selectedIndex: options.isEmpty ? nil : 0)
        }
        // Anyone not in Contacts can be invited by typing their address.
        d.invitees += emails.map { InviteeChoice(query: $0, options: [ContactSearch.Person(name: $0, email: $0)], selectedIndex: 0) }
        return d
    }

    /// Waits for a pending refinement so what gets saved matches the final preview.
    func finalDraft() async -> DraftEvent? {
        await task?.value
        return draft
    }

    func clear() {
        task?.cancel()
        text = ""
        draft = nil
        refining = false
    }
}

enum RuleParser {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let timeRx = try! NSRegularExpression(pattern: #"\d\s*(am|pm|a\.m\.|p\.m\.)|\d{1,2}[:.]\d{2}|\bnoon\b|\bmidnight\b"#, options: .caseInsensitive)
    private static let durationRx = try! NSRegularExpression(pattern: #"\bfor\s+(\d+(?:\.\d+)?)\s*(minutes?|mins?|m|hours?|hrs?|h)\b"#, options: .caseInsensitive)
    private static let locationRx = try! NSRegularExpression(pattern: #"\s(?:in|at|@)\s+(.+)$"#, options: .caseInsensitive)
    private static let danglingRx = try! NSRegularExpression(pattern: #"\s+(at|on|from|by|for|in)\s*$"#, options: .caseInsensitive)

    /// Capitalised names after "with": "with Nathan and Kate Lee" → ["Nathan", "Kate Lee"].
    static func people(in text: String) -> [String] {
        let name = #"\p{Lu}[\p{L}'’-]+(?:\s+\p{Lu}[\p{L}'’-]+)?"#
        let rx = try! NSRegularExpression(pattern: #"\bwith\s+("# + name + #"(?:\s*(?:,|&|\band\b)\s*"# + name + #")*)"#)
        guard let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return [] }
        return text[r]
            .replacingOccurrences(of: #"\s*(,|&|\band\b)\s*"#, with: "|", options: .regularExpression)
            .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func emails(in text: String) -> [String] {
        let rx = try! NSRegularExpression(pattern: #"[\w.+'-]+@[\w-]+(?:\.[\w-]+)+"#)
        return rx.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    static func parse(_ input: String, now: Date = Date()) -> DraftEvent? {
        let cal = Calendar.current
        var s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        var duration: TimeInterval = 3600
        if let m = durationRx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let n = Double((s as NSString).substring(with: m.range(at: 1))) {
            let unit = (s as NSString).substring(with: m.range(at: 2)).lowercased()
            duration = unit.hasPrefix("h") ? n * 3600 : n * 60
            s = (s as NSString).replacingCharacters(in: m.range, with: "")
        }

        var dayDate: Date?, timeDate: Date?, timeEnd: Date?
        var ranges: [NSRange] = []
        for m in detector.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let d = m.date else { continue }
            let frag = (s as NSString).substring(with: m.range)
            if timeRx.firstMatch(in: frag, range: NSRange(frag.startIndex..., in: frag)) != nil {
                if timeDate == nil {
                    timeDate = d
                    if m.duration > 0 { timeEnd = d.addingTimeInterval(m.duration) }
                }
            } else if dayDate == nil {
                dayDate = d
            }
            ranges.append(m.range)
        }
        // Remove date fragments (and the preposition in front of each) from the title.
        for r in ranges.sorted(by: { $0.location > $1.location }) {
            var head = (s as NSString).substring(to: r.location)
            let tail = (s as NSString).substring(from: r.location + r.length)
            head = danglingRx.stringByReplacingMatches(in: head, range: NSRange(head.startIndex..., in: head), withTemplate: "")
            s = head + " " + tail
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        var location: String?
        if let m = locationRx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            location = (s as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            s = (s as NSString).substring(to: m.range.location)
        }
        s = danglingRx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        let title = s.isEmpty ? "New Event" : s

        let hasYear = input.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil
        func rollForward(_ d: Date) -> Date {
            !hasYear && d < cal.startOfDay(for: now) ? cal.date(byAdding: .year, value: 1, to: d)! : d
        }

        switch (dayDate, timeDate) {
        case let (day?, time?):
            var c = cal.dateComponents([.year, .month, .day], from: rollForward(day))
            let t = cal.dateComponents([.hour, .minute], from: time)
            c.hour = t.hour; c.minute = t.minute
            let start = cal.date(from: c)!
            let end = timeEnd.map { start.addingTimeInterval($0.timeIntervalSince(time)) } ?? start.addingTimeInterval(duration)
            return DraftEvent(title: title, start: start, end: end, allDay: false, location: location)
        case let (nil, time?):
            return DraftEvent(title: title, start: time, end: timeEnd ?? time.addingTimeInterval(duration), allDay: false, location: location)
        case let (day?, nil):
            let start = cal.startOfDay(for: rollForward(day))
            return DraftEvent(title: title, start: start, end: start, allDay: true, location: location)
        case (nil, nil):
            let nextHour = cal.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)!
            return DraftEvent(title: title, start: nextHour, end: nextHour.addingTimeInterval(duration), allDay: false, location: location)
        }
    }
}

/// The small on-device model is unreliable at date arithmetic (tested: wrong weekdays, invented
/// attendees), so dates stay with RuleParser and the model only cleans up the title and place.
@Generable
struct ParsedText {
    @Guide(description: "Concise event title using only words from the input, typos fixed. No date, time or place.")
    var title: String
    @Guide(description: "Venue or place exactly as written in the input, or empty string when none.")
    var location: String
}

enum AIParser {
    static func refine(_ text: String, base: DraftEvent) async -> DraftEvent? {
        let session = LanguageModelSession(instructions: """
            Extract the event title and the place from one short calendar entry a user typed. \
            The text may contain typos or leftover filler words; drop them from the title.
            """)
        do {
            let p = try await session.respond(to: text, generating: ParsedText.self).content
            let title = p.title.trimmingCharacters(in: .whitespaces)
            let loc = p.location.trimmingCharacters(in: .whitespaces)
            var d = base
            if !title.isEmpty { d.title = title }
            // The model happily labels "friday" a place; it may only tidy a location the rules found.
            if base.location != nil, !loc.isEmpty, text.localizedCaseInsensitiveContains(loc) { d.location = loc }
            return d
        } catch {
            return nil
        }
    }
}
