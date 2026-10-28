import EventKit
import SwiftUI

/// Fantastical-style event popover: join link, a label/value form, invitees, propose new time,
/// notes and your RSVP status. Fields are editable when the event is yours; invitations are read-only
/// apart from the response.
struct EventInspector: View {
    static let paper = Color(red: 0.97, green: 0.98, blue: 0.99)
    static let link = Color(red: 0.10, green: 0.42, blue: 0.93)

    @Environment(CalendarStore.self) private var store
    let event: EKEvent

    @State private var title = ""
    @State private var location = ""
    @State private var allDay = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var calendarID = ""
    @State private var alert: Int?
    @State private var availability = EKEventAvailability.busy
    @State private var comment = ""
    @State private var proposing = false
    @State private var proposedStart = Date()
    @State private var notesExpanded = false
    @State private var notes = ""
    @State private var inviteQuery = ""
    @State private var revision = 0   // bumped after invitee edits; EKEvent isn't observable
    @State private var loaded = false

    var body: some View {
        let editable = store.canEdit(event)
        let link = MeetingLink.find(in: event)

        let canInvite = store.canInvite(event)
        let _ = revision

        VStack(alignment: .leading, spacing: 0) {
            header(editable: editable, link: link)
                .padding(.bottom, 10)
            if store.isInvitation(event) {
                section { response }
            }
            form(editable: editable)
                .padding(.bottom, 10)
            if !attendeeList.isEmpty || canInvite {
                section { invitees(attendeeList, canInvite: canInvite) }
            }
            if editable {
                section { notesEditor }
            } else if let text = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                section { notesView(text) }
            }
            section { footer(editable: editable) }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color(white: 0.1))
        .tint(Self.link)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
        // Opaque like Fantastical; the default glass lets the dark agenda bleed through.
        .background(Self.paper)
        .presentationBackground(Self.paper)
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .onAppear(perform: load)
        .onDisappear { commit() }
    }

    // MARK: Sections

    private func section<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.horizontal, -14)
            content().padding(.vertical, 4)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private func header(editable: Bool, link: MeetingLink?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if editable {
                TextField("New Event", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .onSubmit(commit)
            } else {
                Text(event.title ?? "Untitled").font(.system(size: 16, weight: .semibold))
                    .textSelection(.enabled)
            }
            if let link {
                Button { link.open() } label: {
                    Label("Join \(link.longLabel)", systemImage: "video.fill")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Self.link)
            }
            if editable {
                TextField("Add Location", text: $location)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
                    .onSubmit(commit)
            } else if !location.isEmpty, !location.hasPrefix("http") {
                Text(location).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func form(editable: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            row("all-day") {
                Toggle("", isOn: $allDay).labelsHidden().toggleStyle(.checkbox).disabled(!editable)
                    .onChange(of: allDay) { if loaded { commit() } }
            }
            row("starts") { dateField($start, editable: editable) }
            row("ends") { dateField($end, editable: editable) }
            if !allDay, let tz = event.timeZone, tz != .current {
                row("time zone") {
                    let hours = Double(tz.secondsFromGMT(for: event.startDate)) / 3600
                    let offset = hours == hours.rounded() ? String(format: "%+.0f", hours) : String(format: "%+.1f", hours)
                    Text("\(tz.localizedName(for: .generic, locale: .current) ?? tz.identifier) (\(offset))")
                }
            }
            row("calendar") {
                if editable {
                    Picker("", selection: $calendarID) {
                        ForEach(movableCalendars, id: \.calendarIdentifier) { c in
                            Label { Text(c.title) } icon: { Image(nsImage: dot(c)) }.tag(c.calendarIdentifier)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 190, alignment: .leading)
                    .onChange(of: calendarID) { if loaded { commit() } }
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(Color(cgColor: event.calendar.cgColor)).frame(width: 8, height: 8)
                        Text(event.calendar.title).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            row("repeat") { Text(Recurrence.describe(event)) }
            if let end = Recurrence.end(event) {
                row("repeat end") { Text(end) }
            }
            row("alert") {
                if editable {
                    Picker("", selection: $alert) {
                        ForEach(AlertOption.all, id: \.minutes) { Text($0.title).tag($0.minutes) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: alert) { if loaded { commit() } }
                } else {
                    Text(AlertOption.title(for: alert))
                }
            }
            row("show as") {
                if editable && !event.calendar.supportedEventAvailabilities.isEmpty {
                    Picker("", selection: $availability) {
                        Text("Busy").tag(EKEventAvailability.busy)
                        Text("Free").tag(EKEventAvailability.free)
                        if event.calendar.supportedEventAvailabilities.contains(.tentative) {
                            Text("Tentative").tag(EKEventAvailability.tentative)
                        }
                        if event.calendar.supportedEventAvailabilities.contains(.unavailable) {
                            Text("Away").tag(EKEventAvailability.unavailable)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: availability) { if loaded { commit() } }
                } else {
                    Text(availabilityTitle(event.availability))
                }
            }
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing)
            value()
        }
    }

    @ViewBuilder private func dateField(_ date: Binding<Date>, editable: Bool) -> some View {
        if editable {
            DatePicker("", selection: date, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.field)
                .onChange(of: date.wrappedValue) { if loaded { commit() } }
        } else {
            HStack(spacing: 0) {
                Text(date.wrappedValue.formatted(date: .numeric, time: .omitted))
                    .frame(width: 96, alignment: .leading)
                if !allDay { Text(date.wrappedValue.formatted(date: .omitted, time: .shortened)) }
            }
        }
    }

    private func invitees(_ list: [(EKParticipant, String)], canInvite: Bool) -> some View {
        let suggestions = canInvite ? ContactSearch.search(inviteQuery, preferDomain: store.workDomain, limit: 5) : []
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(list, id: \.0.url) { p, role in
                HStack(spacing: 7) {
                    statusIcon(p.participantStatus)
                    Text(p.url.absoluteString.hasPrefix("mailto:") ? String(p.url.absoluteString.dropFirst(7)) : (p.name ?? p.url.absoluteString))
                        .lineLimit(1).truncationMode(.middle)
                        .help(p.name ?? "")
                    if !role.isEmpty { Text(role).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if canInvite && role.isEmpty {
                        Button { store.removeInvitee(event, p); revision += 1 } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove invitee")
                    }
                }
            }
            if canInvite {
                TextField("Add Invitees (name or email)", text: $inviteQuery)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
                    .onSubmit {
                        if let p = suggestions.first { invite(p.name, p.email) }
                        else if inviteQuery.contains("@") { invite(nil, inviteQuery.trimmingCharacters(in: .whitespaces)) }
                    }
                    .onChange(of: inviteQuery) {
                        if ContactSearch.undetermined {
                            Task { if await ContactSearch.requestAccess() { revision += 1 } }
                        }
                    }
                ForEach(suggestions) { p in
                    Button { invite(p.name, p.email) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.name)
                            Text(p.email).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
        }
    }

    private func invite(_ name: String?, _ email: String) {
        store.addInvitee(event, name: name, email: email)
        inviteQuery = ""
        revision += 1
    }

    private var notesEditor: some View {
        ZStack(alignment: .topLeading) {
            if notes.isEmpty {
                Text("Add Notes or an agenda").foregroundStyle(.tertiary).padding(.leading, 5)
            }
            TextEditor(text: $notes)
                .scrollContentBackground(.hidden)
                .font(.system(size: 13))
                .frame(minHeight: 60, maxHeight: 220)
        }
    }

    @ViewBuilder private var propose: some View {
        if proposing {
            VStack(alignment: .leading, spacing: 6) {
                DatePicker("New start", selection: $proposedStart).datePickerStyle(.field)
                let minutes = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
                Text("Keeps the \(minutes)-minute duration").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("Maybe + propose") { send(.maybe, proposing: proposedStart) }
                    Button("Decline + propose") { send(.decline, proposing: proposedStart) }
                    Button("Cancel") { proposing = false }
                }
                .controlSize(.small)
                if !store.canProposeTime(event) {
                    Text("This account's server doesn't take proposals from macOS, so the new time is sent to the organiser by email.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        } else {
            Button {
                proposedStart = event.startDate
                proposing = true
            } label: {
                Label("Propose New Time…", systemImage: "calendar.badge.clock")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
                    .foregroundStyle(Self.link)
            }
            .buttonStyle(.plain)
        }
    }

    private func notesView(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Linkify.attributed(notes))
                .lineLimit(notesExpanded ? nil : 10)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !notesExpanded && notes.split(whereSeparator: \.isNewline).count > 10 {
                Button("Show more") { notesExpanded = true }
                    .buttonStyle(.plain).foregroundStyle(Self.link).font(.system(size: 12))
            }
        }
    }

    @ViewBuilder private var response: some View {
        if store.canRespond(event) {
            let current = store.status(of: event)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    rsvpButton("Accept", .accept, active: current == .accepted, tint: .green)
                    rsvpButton("Maybe", .maybe, active: current == .tentative, tint: .orange)
                    rsvpButton("Decline", .decline, active: current == .declined, tint: .red)
                }
                TextField("Add a comment to your response", text: $comment, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                if !comment.isEmpty && !store.canComment(event) {
                    Text("This account can't attach comments to a response, so Ubercal will also open an email to the organiser.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                propose
            }
        } else {
            Text("Respond in Calendar — this account doesn't allow it here.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func rsvpButton(_ title: String, _ rsvp: CalendarStore.RSVP, active: Bool, tint: Color) -> some View {
        Button { send(rsvp) } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? tint : Color.black.opacity(0.06)))
                .foregroundStyle(active ? Color.white : Color(white: 0.1))
        }
        .buttonStyle(.plain)
    }

    /// Native response first; whatever the server can't carry (comment, proposed time) goes by email.
    private func send(_ rsvp: CalendarStore.RSVP, proposing newStart: Date? = nil) {
        let nativeComment = store.canComment(event)
        let nativePropose = store.canProposeTime(event)
        store.respond(event, rsvp, proposing: nativePropose ? newStart : nil, comment: nativeComment ? comment : "")
        let mailPropose = newStart != nil && !nativePropose
        let mailComment = !comment.isEmpty && !nativeComment
        if mailPropose || mailComment {
            store.emailOrganizer(event, rsvp: rsvp, proposing: mailPropose ? newStart : nil, comment: mailComment ? comment : "")
        }
        comment = ""
        proposing = false
    }

    private func footer(editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if event.hasRecurrenceRules && editable {
                Text("Edits apply to this occurrence only").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Button("Open in Calendar") { store.openInCalendar(event) }
                if editable {
                    Button("Delete", role: .destructive) { store.delete(event) }.foregroundStyle(Theme.year)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Self.link)
            .fixedSize()
        }
    }

    // MARK: Data

    private var attendeeList: [(EKParticipant, String)] {
        guard let attendees = event.attendees else { return [] }
        var list: [(EKParticipant, String)] = []
        if let org = event.organizer {
            list.append((org, org.isCurrentUser ? "(organizer, me)" : "(organizer)"))
        }
        for a in attendees where a.url != event.organizer?.url {
            list.append((a, a.isCurrentUser ? "(me)" : ""))
        }
        return list
    }

    private var movableCalendars: [EKCalendar] {
        // EventKit can't move events between accounts, only between calendars of one account.
        store.writableCalendars.filter { $0.source.sourceIdentifier == event.calendar.source.sourceIdentifier }
    }

    private func load() {
        title = event.title ?? ""
        location = event.location ?? ""
        allDay = event.isAllDay
        start = event.startDate
        end = event.endDate
        calendarID = event.calendar.calendarIdentifier
        alert = event.alarms?.first.map { Int(-$0.relativeOffset / 60) }
        availability = event.availability == .notSupported ? .busy : event.availability
        notes = event.notes ?? ""
        DispatchQueue.main.async { loaded = true }
    }

    private func commit() {
        guard loaded, store.canEdit(event) else { return }
        var changed = false
        func set<T: Equatable>(_ current: T, _ new: T, _ apply: () -> Void) {
            if current != new { apply(); changed = true }
        }
        set(event.title ?? "", title) { event.title = title }
        set(event.location ?? "", location) { event.location = location.isEmpty ? nil : location }
        set(event.notes ?? "", notes) { event.notes = notes.isEmpty ? nil : notes }
        set(event.isAllDay, allDay) { event.isAllDay = allDay }
        if start != event.startDate || end != event.endDate {
            let duration = event.endDate.timeIntervalSince(event.startDate)
            if start != event.startDate && end == event.endDate { end = start.addingTimeInterval(duration) }
            if end < start { end = start.addingTimeInterval(duration) }
            event.startDate = start
            event.endDate = end
            changed = true
        }
        if calendarID != event.calendar.calendarIdentifier, let c = store.ek.calendar(withIdentifier: calendarID) {
            event.calendar = c
            changed = true
        }
        let currentAlert = event.alarms?.first.map { Int(-$0.relativeOffset / 60) }
        set(currentAlert, alert) {
            event.alarms = alert.map { [EKAlarm(relativeOffset: TimeInterval(-$0 * 60))] }
        }
        if event.availability != .notSupported {
            set(event.availability, availability) { event.availability = availability }
        }
        if changed { store.save(event) }
    }

    // MARK: Small pieces

    private func statusIcon(_ s: EKParticipantStatus) -> some View {
        let (name, color): (String, Color) = switch s {
        case .accepted: ("checkmark.circle.fill", .green)
        case .declined: ("xmark.circle.fill", .red)
        case .tentative: ("questionmark.circle.fill", .orange)
        default: ("circle.dashed", .secondary)
        }
        return Image(systemName: name).foregroundStyle(.white, color).font(.system(size: 15))
    }

    private func availabilityTitle(_ a: EKEventAvailability) -> String {
        switch a {
        case .free: "Free"
        case .tentative: "Tentative"
        case .unavailable: "Away"
        default: "Busy"
        }
    }

    private func dot(_ c: EKCalendar) -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            NSColor(cgColor: c.cgColor)?.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
    }
}

struct AlertOption {
    let minutes: Int?
    let title: String

    static let all: [AlertOption] = [
        AlertOption(minutes: nil, title: "None"),
        AlertOption(minutes: 0, title: "At time of event"),
        AlertOption(minutes: 5, title: "5 minutes before"),
        AlertOption(minutes: 10, title: "10 minutes before"),
        AlertOption(minutes: 15, title: "15 minutes before"),
        AlertOption(minutes: 30, title: "30 minutes before"),
        AlertOption(minutes: 60, title: "1 hour before"),
        AlertOption(minutes: 120, title: "2 hours before"),
        AlertOption(minutes: 1440, title: "1 day before"),
    ]

    static func title(for minutes: Int?) -> String {
        guard let minutes else { return "None" }
        if let known = all.first(where: { $0.minutes == minutes }) { return known.title }
        return minutes % 60 == 0 ? "\(minutes / 60) hours before" : "\(minutes) minutes before"
    }
}

enum Recurrence {
    static func describe(_ e: EKEvent) -> String {
        guard let r = e.recurrenceRules?.first else { return "None" }
        let n = r.interval
        let unit: String = switch r.frequency {
        case .daily: n == 1 ? "day" : "\(n) days"
        case .weekly: n == 1 ? "week" : "\(n) weeks"
        case .monthly: n == 1 ? "month" : "\(n) months"
        case .yearly: n == 1 ? "year" : "\(n) years"
        @unknown default: "period"
        }
        var s = "Every \(unit)"
        if let days = r.daysOfTheWeek, !days.isEmpty {
            let names = Calendar.current.standaloneWeekdaySymbols
            s += " on " + days.map { names[$0.dayOfTheWeek.rawValue - 1] }.formatted(.list(type: .and))
        }
        return s
    }

    static func end(_ e: EKEvent) -> String? {
        guard let r = e.recurrenceRules?.first else { return nil }
        guard let end = r.recurrenceEnd else { return "Never" }
        if let d = end.endDate { return d.formatted(date: .numeric, time: .omitted) }
        return "After \(end.occurrenceCount) times"
    }
}

enum Linkify {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        for m in detector.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let url = m.url, let r = Range(m.range, in: s), let ar = Range(r, in: a) else { continue }
            a[ar].link = url
            a[ar].underlineStyle = .single
        }
        return a
    }
}
