import EventKit
import ServiceManagement
import SwiftUI

enum Theme {
    static let topBg = Color(white: 0.965)
    static let bottomBg = Color(white: 0.13)
    static let accent = Color(red: 0.29, green: 0.53, blue: 0.97)
    static let year = Color(red: 0.80, green: 0.25, blue: 0.18)
    static let width: CGFloat = 320
}

struct PopoverView: View {
    @Environment(CalendarStore.self) private var store
    @State private var quick = QuickAddModel()
    @State private var searching = false
    @State private var showInvites = false
    @State private var created: CreatedEvent?
    @State private var scrollToNow = 0
    @State private var agendaHeight: CGFloat = 370
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            top
                .background(Theme.topBg)
                .environment(\.colorScheme, .light)
            bottom
                .frame(maxHeight: .infinity)
                .background(Theme.bottomBg)
                .environment(\.colorScheme, .dark)
        }
        .frame(width: Theme.width, height: 650)
        .onAppear {
            store.setVisible("popover", true)
            fieldFocused = true
            jumpToNow()
        }
        .onDisappear { store.setVisible("popover", false) }
    }

    // MARK: Top (input + month)

    private var top: some View {
        VStack(spacing: 10) {
            inputRow
            if !searching, let draft = quick.draft {
                DraftPreview(draft: draft, refining: quick.refining, choose: quick.choose)
            }
            if store.access == .denied {
                AccessDeniedView()
            } else {
                MonthHeader(showInvites: $showInvites, today: jumpToNow)
                MonthGrid()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField(searching ? "Search events" : "Lunch with Kate tomorrow 1pm at Cafe Lua",
                      text: $quick.text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($fieldFocused)
                .onSubmit(submit)
                .onExitCommand { quick.clear() }
            Button {
                searching.toggle()
                showInvites = false
                fieldFocused = true
            } label: {
                Image(systemName: searching ? "xmark.circle.fill" : "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(searching ? "Back to quick add" : "Search")
        }
        .frame(height: 28)
        // The new event's card opens right away so notes/agenda and invitees can be added.
        .popover(item: $created, arrowEdge: .leading) { EventInspector(event: $0.event).environment(store) }
        .onAppear { quick.preferDomain = store.workDomain }
    }

    private func submit() {
        guard !searching else { return }
        Task {
            guard let draft = await quick.finalDraft() else { return }
            if let e = store.create(draft, in: nil) {
                quick.clear()
                created = CreatedEvent(event: e)
            }
        }
    }

    // MARK: Bottom (agenda)

    /// Today, scrolled to the meeting in progress (or the next one).
    private func jumpToNow() {
        searching = false
        showInvites = false
        store.goToToday()
        scrollToNow += 1
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        // Let the list lay out today's rows before scrolling to one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let e = store.currentOrNextEvent() {
                // scrollTo aligns the same unit point of row and viewport; pick the point that
                // leaves the row's top one sticky-header height below the viewport top.
                let y = Agenda.headerHeight / max(1, agendaHeight - Agenda.typicalRowHeight)
                proxy.scrollTo(Agenda.anchorID(e), anchor: UnitPoint(x: 0, y: y))
            } else {
                proxy.scrollTo("agenda-top", anchor: .top)
            }
        }
    }

    @ViewBuilder private var bottom: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    Color.clear.frame(height: 0).id("agenda-top")
                    if searching {
                        SearchResults(query: quick.text)
                    } else if showInvites {
                        InviteList(close: { showInvites = false })
                    } else {
                        Agenda()
                    }
                }
                .padding(.bottom, 64)
            }
            .scrollIndicators(.automatic)
            // onAppear covers the first open (the counter changes before this view exists).
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { agendaHeight = $0 }
            .onAppear { scrollToCurrent(proxy) }
            .onChange(of: scrollToNow) { scrollToCurrent(proxy) }
            .onChange(of: store.selectedDay) {
                if !store.cal.isDateInToday(store.selectedDay) { proxy.scrollTo("agenda-top", anchor: .top) }
            }
            }
            VStack(spacing: 6) {
                if let err = store.lastError {
                    ErrorBanner(message: err) { store.lastError = nil }
                }
                Footer(showInvites: $showInvites)
            }
        }
    }
}

// MARK: - Quick add preview

struct CreatedEvent: Identifiable {
    let id = UUID()
    let event: EKEvent
}

struct DraftPreview: View {
    @Environment(CalendarStore.self) private var store
    let draft: DraftEvent
    let refining: Bool
    var choose: ((Int, Int?) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(cgColor: store.defaultCalendar?.cgColor ?? CGColor(gray: 0.5, alpha: 1)))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title).font(.system(size: 13, weight: .semibold))
                Text(when).font(.system(size: 12)).foregroundStyle(.secondary)
                if let loc = draft.location {
                    Label(loc, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(draft.invitees.indices, id: \.self) { i in
                    invitee(i, draft.invitees[i])
                }
            }
            Spacer()
            if refining {
                ProgressView().controlSize(.small)
            } else {
                Text("↩︎ add").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.05)))
    }

    @ViewBuilder private func invitee(_ i: Int, _ c: InviteeChoice) -> some View {
        Menu {
            ForEach(c.options.indices, id: \.self) { o in
                Button("\(c.options[o].name) — \(c.options[o].email)") { choose?(i, o) }
            }
            if !c.options.isEmpty { Divider() }
            Button("Don't invite") { choose?(i, nil) }
        } label: {
            Label(c.selected.map { "Invite \($0.name)" }
                  ?? (c.options.isEmpty ? "\(c.query): not in Contacts" : "\(c.query): not invited"),
                  systemImage: c.selected == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(c.options.isEmpty ? .hidden : .visible)
        .fixedSize()
        .font(.system(size: 12))
        .foregroundStyle(c.selected == nil ? Color.secondary : Theme.accent)
        .help(c.selected?.email ?? "")
    }

    private var when: String {
        let day = draft.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        if draft.allDay { return "\(day) · all-day" }
        return "\(day) · \(TimeFormat.range(draft.start, draft.end))"
    }
}

// MARK: - Month

private struct MonthHeader: View {
    @Environment(CalendarStore.self) private var store
    @Binding var showInvites: Bool
    let today: () -> Void

    private var onToday: Bool {
        store.cal.isDate(store.selectedDay, inSameDayAs: store.today)
            && store.cal.isDate(store.month, equalTo: store.today, toGranularity: .month)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: today) {
                let year = Text(store.month.formatted(.dateTime.year())).foregroundStyle(Theme.year)
                Text("\(store.month.formatted(.dateTime.month(.wide))) \(year)")
                    .font(.system(size: 28, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("t")
            .help("Go to today (⌘T)")

            if !store.pending.isEmpty {
                Button { showInvites.toggle() } label: {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.year))
                }
                .buttonStyle(.plain)
                .help("\(store.pending.count) invitation(s) awaiting response")
            }
            Spacer(minLength: 4)
            // Only takes room when you've navigated away; ⌘T (on the title) works either way.
            if !onToday {
                Button(action: today) {
                    Text("Today")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.06)))
                }
                .help("Jump to today (⌘T)")
            }
            Button { store.shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Button { store.shiftMonth(1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.plain)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.secondary)
    }
}

private struct MonthGrid: View {
    @Environment(CalendarStore.self) private var store

    var body: some View {
        let cal = store.cal
        let start = store.gridStart
        let symbols = cal.shortStandaloneWeekdaySymbols
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 }
        let todayWeekday = cal.component(.weekday, from: store.today) - 1

        // Sizes measured from a Fantastical popover capture at the same 320 pt width.
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(order, id: \.self) { i in
                    Text(symbols[i].uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(i == todayWeekday ? Theme.accent : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 9)

            ForEach(0..<6, id: \.self) { week in
                let days = (0..<7).map { cal.date(byAdding: .day, value: week * 7 + $0, to: start)! }
                let selectedWeek = days.contains { cal.isDate($0, inSameDayAs: store.selectedDay) }
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { DayCell(day: $0) }
                }
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(selectedWeek ? Color.black.opacity(0.06) : .clear).padding(.vertical, 1))
            }
        }
    }
}

private struct DayCell: View {
    @Environment(CalendarStore.self) private var store
    let day: Date

    var body: some View {
        let cal = store.cal
        let selected = cal.isDate(day, inSameDayAs: store.selectedDay)
        let isToday = cal.isDate(day, inSameDayAs: store.today)
        let inMonth = cal.isDate(day, equalTo: store.month, toGranularity: .month)
        let colors = store.dots[cal.startOfDay(for: day)] ?? []

        Button { store.select(day) } label: {
            VStack(spacing: 2.5) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 13, weight: selected || isToday ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : isToday ? Theme.accent : inMonth ? .primary : .secondary)
                HStack(spacing: 1.5) {
                    ForEach(colors.indices, id: \.self) { i in
                        Circle()
                            .fill(selected ? Color.white : Color(cgColor: colors[i]))
                            .frame(width: 3.5, height: 3.5)
                    }
                }
                .frame(height: 3.5)
                .opacity(inMonth || selected ? 1 : 0.6)
            }
            .frame(width: 30, height: 26)
            .background(Circle().fill(selected ? Theme.accent : .clear).frame(width: 30, height: 30))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AccessDeniedView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Calendar access is off").font(.headline)
            Text("Allow Ubercal in System Settings › Privacy & Security › Calendars (Full Access).")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
        }
        .padding(.vertical, 30)
    }
}

// MARK: - Agenda

private struct Agenda: View {
    @Environment(CalendarStore.self) private var store
    static let headerHeight: CGFloat = 34
    static let typicalRowHeight: CGFloat = 50
    static func anchorID(_ e: EKEvent) -> String { "now-" + e.rowID }

    var body: some View {
        ForEach(0..<CalendarStore.listDays, id: \.self) { offset in
            let day = store.cal.date(byAdding: .day, value: offset, to: store.selectedDay)!
            let events = store.events(on: day)
            if offset == 0 || !events.isEmpty {
                Section {
                    if events.isEmpty {
                        Text("No events")
                            .font(.system(size: 13)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    ForEach(events, id: \.rowID) { e in
                        // A marker one pinned-header height above the row, so scrolling to it
                        // leaves the row visible below the sticky day header.
                        // Scroll target as a background: an .id on EventRow itself isn't found by scrollTo.
                        EventRow(event: e, day: day)
                            .background { Color.clear.id(Agenda.anchorID(e)) }
                    }
                } header: {
                    DayHeader(day: day, showWeather: offset == 0)
                }
            }
        }
    }
}

struct DayHeader: View {
    @Environment(CalendarStore.self) private var store
    let day: Date
    var showWeather = false

    var body: some View {
        let cal = store.cal
        let name: String = if cal.isDateInToday(day) { "TODAY" }
            else if cal.isDateInTomorrow(day) { "TOMORROW" }
            else if cal.isDateInYesterday(day) { "YESTERDAY" }
            else { day.formatted(.dateTime.weekday(.wide)).uppercased() }
        let color = cal.isDateInToday(day) ? Theme.accent : Color(white: 0.75)

        HStack(spacing: 6) {
            Text(name).font(.system(size: 13, weight: .bold))
            Text(day.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()))
                .font(.system(size: 13))
            Spacer()
            if let w = store.weather.day(day) {
                Text("\(w.high)°/\(w.low)°").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.85))
                Image(systemName: w.symbol).font(.system(size: 15)).foregroundStyle(Color(white: 0.85))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.bottomBg)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }
}

struct SearchResults: View {
    @Environment(CalendarStore.self) private var store
    let query: String

    var body: some View {
        let results = store.search(query)
        let days = Dictionary(grouping: results) { store.cal.startOfDay(for: $0.startDate) }
        if results.isEmpty {
            Text(query.count < 2 ? "Type to search the past 60 days and the next year" : "No matches")
                .font(.system(size: 13)).foregroundStyle(.tertiary).padding(16)
        }
        ForEach(days.keys.sorted(), id: \.self) { day in
            Section {
                ForEach(days[day]!, id: \.rowID) { EventRow(event: $0, day: day) }
            } header: { DayHeader(day: day) }
        }
    }
}

struct InviteList: View {
    @Environment(CalendarStore.self) private var store
    let close: () -> Void

    var body: some View {
        Section {
            if store.pending.isEmpty {
                Text("No unanswered invitations in the next 60 days")
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            ForEach(store.pending, id: \.rowID) { EventRow(event: $0, day: $0.startDate, showDate: true) }
        } header: {
            HStack {
                Text("INVITATIONS").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.year)
                Spacer()
                Button("Done", action: close).buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Theme.bottomBg)
        }
    }
}

// MARK: - Footer

private struct Footer: View {
    @Environment(CalendarStore.self) private var store
    @Binding var showInvites: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var useAI = QuickAddModel.aiEnabled

    var body: some View {
        HStack {
            Menu {
                Button("Open Ubercal Window") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Button("Unanswered Invitations (\(store.pending.count))") { showInvites = true }
                    .keyboardShortcut("i")
                Button("Go to Today") { store.goToToday() }
                Button("Open Calendar") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                }
                Button("Refresh") { store.reload() }
                Divider()
                Button("Quit Ubercal") { NSApp.terminate(nil) }
            } label: {
                circle("line.3.horizontal")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

            Spacer()
            calendarMenu
            Spacer()

            Menu {
                Picker("New events go to", selection: Binding(
                    get: { store.defaultCalendar?.calendarIdentifier ?? "" },
                    set: { store.defaultCalendarID = $0 })) {
                    ForEach(store.writableCalendars, id: \.calendarIdentifier) {
                        Text("\($0.title) — \($0.source.title)").tag($0.calendarIdentifier)
                    }
                }
                Toggle("Use Apple Intelligence for quick add", isOn: $useAI)
                    .disabled(!QuickAddModel.aiAvailable)
                    .onChange(of: useAI) { QuickAddModel.aiEnabled = useAI }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            store.lastError = "Launch at login: \(error.localizedDescription)"
                        }
                    }
            } label: {
                circle("gearshape")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 8)
        .background(LinearGradient(colors: [Theme.bottomBg.opacity(0), Theme.bottomBg], startPoint: .top, endPoint: .center))
    }

    private var calendarMenu: some View {
        Menu {
            CalendarFilterItems()
        } label: {
            HStack(spacing: 4) {
                Text(store.calendarFilterTitle).font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 30)
            .background(Capsule().fill(Color(white: 0.28)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 31, height: 31)
            .background(Circle().fill(Color(white: 0.28)))
            .overlay(Circle().stroke(Color.white.opacity(0.12)))
    }
}

/// Per-account calendar toggles, shared by the popover footer and the window toolbar.
struct CalendarFilterItems: View {
    @Environment(CalendarStore.self) private var store

    var body: some View {
        let sources = Dictionary(grouping: store.calendars, by: { $0.source.title })
        Button("Show All") { store.hiddenCalendarIDs = [] }
        ForEach(sources.keys.sorted(), id: \.self) { source in
            Section(source) {
                ForEach(sources[source]!, id: \.calendarIdentifier) { c in
                    Toggle(c.title, isOn: Binding(
                        get: { !store.hiddenCalendarIDs.contains(c.calendarIdentifier) },
                        set: { on in
                            if on { store.hiddenCalendarIDs.remove(c.calendarIdentifier) }
                            else { store.hiddenCalendarIDs.insert(c.calendarIdentifier) }
                        }))
                }
            }
        }
    }
}

extension CalendarStore {
    var calendarFilterTitle: String {
        hiddenCalendarIDs.isEmpty ? "All Calendars" : "\(visibleCalendars.count) Calendars"
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).multilineTextAlignment(.leading)
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.year.opacity(0.9)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }
}

extension EKEvent {
    /// Recurring occurrences share an identifier, so include the start date.
    var rowID: String { "\(eventIdentifier ?? calendarItemIdentifier)|\(startDate.timeIntervalSince1970)" }
}

enum TimeFormat {
    private static let interval: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func range(_ a: Date, _ b: Date) -> String { interval.string(from: a, to: b) }
}
