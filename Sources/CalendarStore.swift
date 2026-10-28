import EventKit
import Observation
import SwiftUI

/// Everything comes from the macOS calendar database (EventKit), so any account
/// added in System Settings › Internet Accounts (Google, Exchange, iCloud…) just works.
@MainActor @Observable
final class CalendarStore {
    enum Access { case unknown, granted, denied }
    enum RSVP: Int { case accept = 2, decline = 3, maybe = 4 }   // EKParticipantStatus raw values

    static let listDays = 7

    let ek = EKEventStore()
    let cal = Calendar.autoupdatingCurrent
    let weather = Weather()

    var access: Access = .unknown
    var today: Date
    var month: Date { didSet { ensureFetched() } }
    var selectedDay: Date { didSet { ensureFetched() } }
    var lastError: String?

    private(set) var events: [EKEvent] = []
    private(set) var dots: [Date: [CGColor]] = [:]
    private(set) var calendars: [EKCalendar] = []
    private(set) var pending: [EKEvent] = []

    var hiddenCalendarIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: "hiddenCalendars")
            reload()
        }
    }
    var defaultCalendarID: String? {
        didSet { UserDefaults.standard.set(defaultCalendarID, forKey: "defaultCalendar") }
    }

    /// Bumped on every reload so other views (the window) know to refetch their own range.
    private(set) var revision = 0

    /// While nothing is on screen, store changes only mark data dirty; nothing is fetched.
    private var visibleViews: Set<String> = []
    var isVisible: Bool { !visibleViews.isEmpty }

    func setVisible(_ view: String, _ on: Bool) {
        if on { visibleViews.insert(view) } else { visibleViews.remove(view) }
        if on && dirty { reload() }
        if on { weather.refreshIfStale() }
    }

    private var dirty = true
    private var fetched: Range<Date>?
    private var reloadTask: Task<Void, Never>?

    init() {
        let now = Date()
        today = now
        selectedDay = Calendar.autoupdatingCurrent.startOfDay(for: now)
        month = Calendar.autoupdatingCurrent.dateInterval(of: .month, for: now)!.start
        hiddenCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? [])
        defaultCalendarID = UserDefaults.standard.string(forKey: "defaultCalendar")

        let nc = NotificationCenter.default
        nc.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.storeChanged() }
        }
        nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dayChanged() }
        }
        Task { await requestAccess() }
    }

    // MARK: Access

    func requestAccess() async {
        do {
            access = try await ek.requestFullAccessToEvents() ? .granted : .denied
        } catch {
            access = .denied
        }
        reload()
    }

    // MARK: Fetching

    var gridStart: Date {
        let weekday = cal.component(.weekday, from: month)
        let offset = (weekday - cal.firstWeekday + 7) % 7
        return cal.date(byAdding: .day, value: -offset, to: month)!
    }

    private var neededRange: Range<Date> {
        let gStart = gridStart
        let gEnd = cal.date(byAdding: .day, value: 42, to: gStart)!
        let lEnd = cal.date(byAdding: .day, value: Self.listDays, to: selectedDay)!
        return min(gStart, selectedDay)..<max(gEnd, lEnd)
    }

    private func ensureFetched() {
        let need = neededRange
        if let f = fetched, f.lowerBound <= need.lowerBound, f.upperBound >= need.upperBound { return }
        reload()
    }

    private func storeChanged() {
        guard isVisible else { dirty = true; return }
        // EventKit fires change notifications in bursts while syncing.
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { reload() }
        }
    }

    private func dayChanged() {
        let wasToday = cal.isDate(selectedDay, inSameDayAs: today)
        today = Date()
        if wasToday { goToToday() }
    }

    func reload() {
        guard access == .granted else { return }
        dirty = false
        revision += 1
        calendars = ek.calendars(for: .event).sorted {
            ($0.source.title, $0.title) < ($1.source.title, $1.title)
        }
        let visible = visibleCalendars
        let range = neededRange
        fetched = range
        guard !visible.isEmpty else { events = []; dots = [:]; pending = []; return }

        events = Self.dedupe(ek.events(matching: ek.predicateForEvents(withStart: range.lowerBound, end: range.upperBound, calendars: visible)))
            .sorted { $0.startDate < $1.startDate }

        var d: [Date: [CGColor]] = [:]
        for e in events {
            guard let color = e.calendar.cgColor else { continue }
            var day = cal.startOfDay(for: e.startDate)
            repeat {
                if d[day, default: []].count < 4 { d[day, default: []].append(color) }
                day = cal.date(byAdding: .day, value: 1, to: day)!
            } while day < e.endDate && day < range.upperBound
        }
        dots = d

        indexPeopleIfStale()

        let now = Date()
        let horizon = cal.date(byAdding: .day, value: 60, to: now)!
        pending = ek.events(matching: ek.predicateForEvents(withStart: now, end: horizon, calendars: visible))
            .filter { status(of: $0) == .pending && isInvitation($0) }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Events in an arbitrary range, for the window's views.
    func fetchEvents(_ range: Range<Date>) -> [EKEvent] {
        let visible = visibleCalendars
        guard access == .granted, !visible.isEmpty else { return [] }
        return Self.dedupe(ek.events(matching: ek.predicateForEvents(withStart: range.lowerBound, end: range.upperBound, calendars: visible)))
            .sorted { $0.startDate < $1.startDate }
    }

    /// The same meeting often lands in two accounts (e.g. work invite mirrored to a personal
    /// calendar). Show it once, preferring the copy where you're an attendee so RSVP works.
    static func dedupe(_ events: [EKEvent]) -> [EKEvent] {
        var best: [String: EKEvent] = [:]
        var order: [String] = []
        for e in events {
            let key = "\(e.title ?? "")|\(e.startDate.timeIntervalSince1970)|\(e.endDate.timeIntervalSince1970)"
            if let kept = best[key] {
                if (kept.attendees?.isEmpty ?? true) && !(e.attendees?.isEmpty ?? true) { best[key] = e }
            } else {
                best[key] = e
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }

    /// The work account's email domain (sources are named after their account address).
    var workDomain: String? {
        let personal: Set<String> = ["gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com"]
        return ek.sources.lazy
            .compactMap { $0.title.split(separator: "@").last.map { String($0).lowercased() } }
            .first { $0.contains(".") && !personal.contains($0) }
    }

    private var peopleIndexedAt: Date?

    /// Who you meet with, for invitee suggestions. Rebuilt at most hourly.
    private func indexPeopleIfStale() {
        if let t = peopleIndexedAt, Date().timeIntervalSince(t) < 3600 { return }
        peopleIndexedAt = Date()
        let start = cal.date(byAdding: .day, value: -180, to: Date())!
        let end = cal.date(byAdding: .day, value: 60, to: Date())!
        var counts: [String: (ContactSearch.Person, Int)] = [:]
        for e in ek.events(matching: ek.predicateForEvents(withStart: start, end: end, calendars: nil)) {
            for p in (e.attendees ?? []) + [e.organizer].compactMap({ $0 }) where !p.isCurrentUser {
                let url = p.url.absoluteString
                guard url.lowercased().hasPrefix("mailto:") else { continue }
                let email = String(url.dropFirst(7)).removingPercentEncoding ?? String(url.dropFirst(7))
                let key = email.lowercased()
                let name = (p.name?.isEmpty == false && p.name != email) ? p.name! : email
                let prev = counts[key]
                counts[key] = (prev.map { $0.0.name == $0.0.email ? ContactSearch.Person(name: name, email: email) : $0.0 }
                               ?? ContactSearch.Person(name: name, email: email), (prev?.1 ?? 0) + 1)
            }
        }
        ContactSearch.calendarPeople = counts.values.map { (person: $0.0, count: $0.1) }
    }

    var visibleCalendars: [EKCalendar] {
        calendars.filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
    }

    var writableCalendars: [EKCalendar] {
        calendars.filter(\.allowsContentModifications)
    }

    func events(on day: Date) -> [EKEvent] {
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return events
            .filter { $0.startDate < end && ($0.endDate > start || $0.startDate >= start) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
    }

    /// The meeting in progress, else the next one (all-day events don't count).
    func currentOrNextEvent() -> EKEvent? {
        let now = Date()
        // Walk days in the agenda's own order so ties (same start time) pick the row shown first.
        for offset in 0..<Self.listDays {
            let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
            if let e = events(on: day).first(where: { !$0.isAllDay && $0.endDate > now }) { return e }
        }
        return nil
    }

    func search(_ query: String) -> [EKEvent] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard access == .granted, q.count >= 2 else { return [] }
        let start = cal.date(byAdding: .day, value: -60, to: today)!
        let end = cal.date(byAdding: .day, value: 365, to: today)!
        return ek.events(matching: ek.predicateForEvents(withStart: start, end: end, calendars: visibleCalendars))
            .filter {
                $0.title?.localizedCaseInsensitiveContains(q) == true
                    || $0.location?.localizedCaseInsensitiveContains(q) == true
            }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: Navigation

    func shiftMonth(_ delta: Int) {
        month = cal.date(byAdding: .month, value: delta, to: month)!
    }

    func select(_ day: Date) {
        selectedDay = cal.startOfDay(for: day)
        let m = cal.dateInterval(of: .month, for: day)!.start
        if m != month { month = m }
    }

    func goToToday() {
        today = Date()
        select(today)
    }

    // MARK: Invitations

    func status(of e: EKEvent) -> EKParticipantStatus? {
        e.attendees?.first(where: \.isCurrentUser)?.participantStatus
    }

    func isInvitation(_ e: EKEvent) -> Bool {
        guard let attendees = e.attendees, attendees.contains(where: \.isCurrentUser) else { return false }
        return e.organizer?.isCurrentUser != true
    }

    /// EventKit has no public API for responding; Calendar.app uses these EKEvent methods.
    /// Each one is checked at runtime so an OS change degrades to "Open in Calendar" instead of crashing.
    func canRespond(_ e: EKEvent) -> Bool {
        guard isInvitation(e), (e as NSObject).responds(to: NSSelectorFromString("setParticipationStatus:")) else { return false }
        return privateBool(e, "allowsParticipationStatusModifications") ?? true
    }

    func canProposeTime(_ e: EKEvent) -> Bool {
        guard canRespond(e), (e as NSObject).responds(to: NSSelectorFromString("setProposedStartDate:")) else { return false }
        if privateBool(e, "disallowProposeNewTime") == true { return false }
        return privateBool(e, "serverSupportedProposeNewTime") ?? true
    }

    func respond(_ e: EKEvent, _ rsvp: RSVP, proposing newStart: Date? = nil, comment: String = "") {
        guard canRespond(e) else {
            lastError = "This calendar doesn't allow responding from here. Use Open in Calendar."
            return
        }
        let obj = e as NSObject
        obj.setValue(rsvp.rawValue, forKey: "participationStatus")
        if let newStart {
            obj.setValue(newStart, forKey: "proposedStartDate")
        }
        if !comment.isEmpty, privateBool(e, "allowsResponseCommentModifications") ?? false {
            obj.setValue(comment, forKey: "responseComment")
        }
        let span: EKSpan = privateBool(e, "responseMustApplyToAll") == true ? .futureEvents : .thisEvent
        do {
            try ek.save(e, span: span, commit: true)
        } catch {
            e.reset()
            lastError = "Couldn't send response: \(error.localizedDescription)"
        }
        reload()
    }

    /// Whether a comment can ride along with the RSVP; otherwise Ubercal emails it.
    func canComment(_ e: EKEvent) -> Bool {
        privateBool(e, "allowsResponseCommentModifications") ?? false
    }

    /// Fallback when the server can't carry a comment or a proposed time: a pre-filled email
    /// to the organiser in the default mail app.
    func emailOrganizer(_ e: EKEvent, rsvp: RSVP, proposing newStart: Date?, comment: String) {
        guard let to = e.organizer?.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""), to.contains("@") else {
            lastError = "No organiser email to send to."
            return
        }
        let verb = switch rsvp { case .accept: "Accepted"; case .maybe: "Tentative"; case .decline: "Declined" }
        var body = ""
        if let newStart {
            let end = newStart.addingTimeInterval(e.endDate.timeIntervalSince(e.startDate))
            body += "Could we move this to \(newStart.formatted(.dateTime.weekday(.wide).day().month(.wide))), \(TimeFormat.range(newStart, end))?\n\n"
        }
        if !comment.isEmpty { body += comment + "\n" }
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = to
        c.queryItems = [
            URLQueryItem(name: "subject", value: "\(newStart == nil ? verb : "New time proposed"): \(e.title ?? "")"),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    // MARK: Invitees
    // Also private EventKit API (what Calendar.app uses); the server sends the invitations on save.

    func canInvite(_ e: EKEvent) -> Bool {
        guard canEdit(e),
              let cls = NSClassFromString("EKAttendee"),
              (cls as AnyObject).responds(to: NSSelectorFromString("attendeeWithName:emailAddress:")),
              (e as NSObject).responds(to: NSSelectorFromString("addAttendee:")) else { return false }
        return [.calDAV, .exchange].contains(e.calendar.source.sourceType)
    }

    @discardableResult
    func addInvitee(_ e: EKEvent, name: String?, email: String, save: Bool = true) -> Bool {
        guard canInvite(e), let cls = NSClassFromString("EKAttendee") as AnyObject? else { return false }
        if e.attendees?.contains(where: { $0.url.absoluteString.lowercased() == "mailto:" + email.lowercased() }) == true { return true }
        let obj = e as NSObject
        if (e.attendees ?? []).isEmpty { addOrganizerAndSelf(e) }
        guard let attendee = cls.perform(NSSelectorFromString("attendeeWithName:emailAddress:"), with: name ?? email, with: email)?
            .takeUnretainedValue() else { return false }
        _ = obj.perform(NSSelectorFromString("addAttendee:"), with: attendee)
        if save { self.save(e) }
        return true
    }

    /// Makes the account owner the organiser (and first attendee) before inviting others,
    /// as Calendar.app does; the method takes a BOOL, so it's called through its IMP.
    private func addOrganizerAndSelf(_ e: EKEvent) {
        let obj = e as NSObject
        let forced = NSSelectorFromString("addOrganizerAndSelfAttendeeForNewInvitationInCalendar:force:")
        if obj.responds(to: forced) {
            typealias Fn = @convention(c) (NSObject, Selector, EKCalendar, ObjCBool) -> Void
            unsafeBitCast(obj.method(for: forced), to: Fn.self)(obj, forced, e.calendar, true)
        } else if obj.responds(to: NSSelectorFromString("addOrganizerAndSelfAttendeeForNewInvitation")) {
            _ = obj.perform(NSSelectorFromString("addOrganizerAndSelfAttendeeForNewInvitation"))
        }
    }

    func removeInvitee(_ e: EKEvent, _ p: EKParticipant) {
        let sel = NSSelectorFromString("removeAttendee:")
        guard canInvite(e), (e as NSObject).responds(to: sel) else { return }
        _ = (e as NSObject).perform(sel, with: p)
        save(e)
    }

    private func privateBool(_ e: EKEvent, _ key: String) -> Bool? {
        guard (e as NSObject).responds(to: NSSelectorFromString(key)) else { return nil }
        return (e.value(forKey: key) as? NSNumber)?.boolValue
    }

    // MARK: Editing

    var defaultCalendar: EKCalendar? {
        if let id = defaultCalendarID, let c = ek.calendar(withIdentifier: id), c.allowsContentModifications { return c }
        return ek.defaultCalendarForNewEvents
    }

    func canEdit(_ e: EKEvent) -> Bool {
        e.calendar.allowsContentModifications && !isInvitation(e)
    }

    func save(_ e: EKEvent) {
        do {
            try ek.save(e, span: .thisEvent, commit: true)
        } catch {
            e.reset()
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
        reload()
    }

    @discardableResult
    func create(_ draft: DraftEvent, in calendar: EKCalendar?) -> EKEvent? {
        guard let target = calendar ?? defaultCalendar else {
            lastError = "No writable calendar."
            return nil
        }
        let e = EKEvent(eventStore: ek)
        e.calendar = target
        e.title = draft.title
        e.isAllDay = draft.allDay
        e.startDate = draft.start
        e.endDate = draft.end
        e.location = draft.location
        let invitees = draft.invitees.compactMap(\.selected)
        if !invitees.isEmpty && !canInvite(e) {
            lastError = "\(target.title) can't send invitations (needs a Google or Exchange calendar). Event created without invitees."
        }
        for p in invitees { addInvitee(e, name: p.name, email: p.email, save: false) }
        do {
            try ek.save(e, span: .thisEvent, commit: true)
            select(draft.start)
            reload()
            return e
        } catch {
            lastError = "Couldn't create event: \(error.localizedDescription)"
            return nil
        }
    }

    func delete(_ e: EKEvent) {
        do {
            try ek.remove(e, span: .thisEvent, commit: true)
        } catch {
            lastError = "Couldn't delete: \(error.localizedDescription)"
        }
        reload()
    }

    func openInCalendar(_ e: EKEvent) {
        if let id = e.eventIdentifier,
           let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"),
           NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}
