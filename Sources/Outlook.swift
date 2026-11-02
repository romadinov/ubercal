import AppKit
import EventKit

/// Per-event facts about a OWA (Outlook) event that EventKit can't carry, keyed in the store by the
/// in-memory event's calendarItemIdentifier.
struct GraphMeta {
    let graphID: String
    let status: EKParticipantStatus
    let isInvitation: Bool
    let isSeriesOccurrence: Bool
}

/// The OWA account (a client Microsoft 365) reaches Ubercal by reading Outlook on the web through the
/// shared, already-signed-in agent-browser session (see OutlookReader.swift) — the tenant allows no client
/// but Outlook and caps publishing/sharing at busy-only, and this Mac has no local calendar source to mirror
/// into. Events are built as in-memory EKEvents and merged into the views. It is read-only: no RSVP, no create,
/// no edit (those happen in Outlook itself).
extension CalendarStore {
    /// agent-browser present and the user has turned OWA on.
    var outlookAvailable: Bool { OutlookReader.isInstalled && sparkEnabled }
    /// On, with a live shared session.
    var outlookSignedIn: Bool { outlookAvailable && !outlookNeedsLogin }
    var outlookAccount: String? { outlookAccountName }
    /// Read-only: never a target for new events.
    var outlookTarget: EKCalendar? { nil }

    /// Identity of a OWA event is its display calendar; graphCal is unsaved, stable per launch.
    func isOutlookEvent(_ c: EKCalendar?) -> Bool { c?.calendarIdentifier == graphCal.calendarIdentifier }
    func isOutlookEvent(_ e: EKEvent) -> Bool { isOutlookEvent(e.calendar) }

    func graphMeta(for e: EKEvent) -> GraphMeta? { graphMeta[e.calendarItemIdentifier] }

    /// Read-only, so there's never an invitation to answer here.
    func needsOutlookResponse(_ e: EKEvent) -> Bool { false }

    // MARK: Turn on / off, sign in

    /// Show the OWA calendar. Usually loads at once: Jinnie's shared session is already signed in.
    func outlookEnable() {
        sparkEnabled = true
        Task { await syncGraph(force: true) }
    }

    /// Open a visible Outlook window to sign the shared session back in (used when it has expired). Shared with
    /// Jinnie, so this re-authenticates both; finish, then Refresh OWA.
    func outlookSignIn() {
        sparkEnabled = true
        Task.detached { try? OutlookReader().beginLogin() }
    }

    /// Stop showing OWA in Ubercal. Does not sign out the shared session (Jinnie still uses it).
    func outlookSignOut() {
        sparkEnabled = false
        outlookNeedsLogin = false
        graphEvents = []
        graphMeta = [:]
        graphWindow = nil
        graphSyncedAt = nil
        if defaultCalendarID == "graph" { defaultCalendarID = nil }
        reload()
    }

    // MARK: Sync

    /// The window kept in view from Outlook: wide enough for the agenda, window views and search.
    var graphRange: Range<Date> {
        let start = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: today))!
        let end = cal.date(byAdding: .day, value: 365, to: today)!
        return start..<end
    }

    func syncGraphIfStale() {
        guard outlookAvailable, !graphSyncing, !outlookNeedsLogin else { return }
        if let t = graphSyncedAt, Date().timeIntervalSince(t) < 120 { return }
        Task { await syncGraph() }
    }

    func syncGraph(force: Bool = false) async {
        guard outlookAvailable, !graphSyncing else { return }
        if !force, let t = graphSyncedAt, Date().timeIntervalSince(t) < 120 { return }
        graphSyncing = true
        defer { graphSyncing = false }

        let range = graphRange
        do {
            // The blocking browser read runs off the main actor; EKEvents are built back here on it.
            let parsed = try await Task.detached { try OutlookReader().events() }.value
            var events: [EKEvent] = []
            var meta: [String: GraphMeta] = [:]
            for p in parsed where p.start < range.upperBound && p.end > range.lowerBound {
                let e = EKEvent(eventStore: ek)
                e.calendar = graphCal
                e.title = p.title
                e.isAllDay = p.isAllDay
                e.startDate = p.start
                e.endDate = max(p.end, p.start)
                if p.isTeams { e.location = "Microsoft Teams Meeting" }
                events.append(e)
                meta[e.calendarItemIdentifier] = GraphMeta(
                    graphID: "", status: p.tentative ? .tentative : .accepted,
                    isInvitation: false, isSeriesOccurrence: false)
            }
            graphEvents = events
            graphMeta = meta
            graphWindow = range
            graphSyncedAt = Date()
            outlookNeedsLogin = false
            reload()
        } catch OutlookReader.ReaderError.needsLogin {
            outlookNeedsLogin = true
            graphEvents = []
            graphMeta = [:]
            reload()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// OWA events overlapping a range, for merging into EK results.
    func graphEventsOverlapping(_ range: Range<Date>) -> [EKEvent] {
        graphEvents.filter { $0.startDate < range.upperBound && $0.endDate > range.lowerBound }
    }
}

enum Outlook {
    static let bundleID = "com.microsoft.Outlook"
    static let web = URL(string: "https://outlook.office.com/calendar")!

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var appInstalled: Bool { appURL != nil }

    /// For anything the read-only view can't do (RSVP, edit a series, see the full invite): jump to Outlook.
    static func open() {
        if let app = appURL {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(web)
        }
    }
}
