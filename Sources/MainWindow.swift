import EventKit
import SwiftUI

enum CalMode: String, CaseIterable, Identifiable {
    case day, week, month, quarter, year
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// The window keeps its own date range and fetches only that, independent of the popover.
@MainActor @Observable
final class WindowModel {
    var mode: CalMode = CalMode(rawValue: UserDefaults.standard.string(forKey: "windowMode") ?? "") ?? .month {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "windowMode") }
    }
    var anchor = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    var search = ""
    private(set) var byDay: [Date: [EKEvent]] = [:]
    let cal = Calendar.autoupdatingCurrent

    func add(_ c: Calendar.Component, _ n: Int, _ d: Date) -> Date { cal.date(byAdding: c, value: n, to: d)! }

    func weekStart(_ d: Date) -> Date {
        let offset = (cal.component(.weekday, from: d) - cal.firstWeekday + 7) % 7
        return add(.day, -offset, cal.startOfDay(for: d))
    }

    var monthStart: Date { cal.dateInterval(of: .month, for: anchor)!.start }
    var quarterStart: Date {
        var c = cal.dateComponents([.year, .month], from: anchor)
        c.month = (c.month! - 1) / 3 * 3 + 1
        c.day = 1
        return cal.date(from: c)!
    }
    var quarterWeeks: Int {
        let s = weekStart(quarterStart)
        let days = cal.dateComponents([.day], from: s, to: add(.month, 3, quarterStart)).day!
        return (days + 6) / 7
    }

    var range: Range<Date> {
        switch mode {
        case .day: return anchor..<add(.day, 1, anchor)
        case .week: let s = weekStart(anchor); return s..<add(.day, 7, s)
        case .month: let s = weekStart(monthStart); return s..<add(.day, 42, s)
        case .quarter: let s = weekStart(quarterStart); return s..<add(.day, 7 * quarterWeeks, s)
        case .year:
            let s = cal.dateInterval(of: .year, for: anchor)!.start
            return s..<add(.year, 1, s)
        }
    }

    func step(_ n: Int) {
        anchor = switch mode {
        case .day: add(.day, n, anchor)
        case .week: add(.day, 7 * n, anchor)
        case .month: add(.month, n, monthStart)
        case .quarter: add(.month, 3 * n, quarterStart)
        case .year: add(.year, n, anchor)
        }
    }

    func show(_ day: Date, in mode: CalMode) {
        anchor = cal.startOfDay(for: day)
        self.mode = mode
    }

    var title: (main: String, year: String) {
        let year = anchor.formatted(.dateTime.year())
        switch mode {
        case .day: return (anchor.formatted(.dateTime.weekday(.wide).day().month(.wide)), year)
        case .week, .month: return (anchor.formatted(.dateTime.month(.wide)), year)
        case .quarter:
            let end = add(.month, 2, quarterStart)
            return ("\(quarterStart.formatted(.dateTime.month(.abbreviated))) – \(end.formatted(.dateTime.month(.abbreviated)))", year)
        case .year: return ("", year)
        }
    }

    func refresh(_ store: CalendarStore) {
        let r = range
        var map: [Date: [EKEvent]] = [:]
        for e in store.fetchEvents(r) {
            var day = max(cal.startOfDay(for: e.startDate), r.lowerBound)
            repeat {
                map[day, default: []].append(e)
                day = add(.day, 1, day)
            } while day < e.endDate && day < r.upperBound
        }
        for (k, v) in map {
            map[k] = v.sorted { (isSpanning($0) ? 0 : 1, $0.startDate) < (isSpanning($1) ? 0 : 1, $1.startDate) }
        }
        byDay = map
    }

    /// All-day or crossing midnight: drawn as a bar rather than a dotted line.
    func isSpanning(_ e: EKEvent) -> Bool {
        e.isAllDay || !cal.isDate(e.startDate, inSameDayAs: e.endDate.addingTimeInterval(-1))
    }

    func events(on day: Date) -> [EKEvent] { byDay[cal.startOfDay(for: day)] ?? [] }
}

/// Sizes are measured from a Fantastical month-view capture (window 1512×888 pt): see `Metrics`.
struct MainWindow: View {
    @Environment(CalendarStore.self) private var store
    @State private var model = WindowModel()
    @State private var showAdd = false
    @State private var showInvites = false

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            HStack(spacing: 0) {
                content
                if !model.search.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                            SearchResults(query: model.search)
                        }
                    }
                    .frame(width: 300)
                    .background(Theme.bottomBg)
                    .environment(\.colorScheme, .dark)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 440)
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar { toolbarContent }
        .toolbar(removing: .title)
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search")
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            store.setVisible("window", true)
            model.refresh(store)
        }
        .onDisappear {
            store.setVisible("window", false)
            NSApp.setActivationPolicy(.accessory)
        }
        .onChange(of: store.revision) { model.refresh(store) }
        .onChange(of: model.range) { model.refresh(store) }
        .onChange(of: store.hiddenCalendarIDs) { model.refresh(store) }
    }

    private var titleRow: some View {
        HStack(alignment: .lastTextBaseline) {
            let t = model.title
            let year = Text(t.year).foregroundStyle(Theme.year)
            Text(t.main.isEmpty ? "\(year)" : "\(t.main) \(year)")
                .font(.system(size: Metrics.title, weight: .bold))
            Spacer()
            Menu {
                CalendarFilterItems()
            } label: {
                Text(store.calendarFilterTitle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 25)
        .padding(.bottom, 15)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .day: TimeGrid(model: model, days: [model.anchor])
        case .week: TimeGrid(model: model, days: (0..<7).map { model.add(.day, $0, model.range.lowerBound) })
        case .month: WeeksGrid(model: model, weeks: 6, compact: false)
        case .quarter: WeeksGrid(model: model, weeks: model.quarterWeeks, compact: true)
        case .year: YearGrid(model: model)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showAdd.toggle() } label: { Image(systemName: "plus") }
                .keyboardShortcut("n")
                .help("New event (⌘N)")
                .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                    WindowQuickAdd { draft in
                        model.anchor = store.cal.startOfDay(for: draft.start)
                    }
                    .environment(store)
                }
        }
        ToolbarItemGroup(placement: .navigation) {
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Today") { model.anchor = store.cal.startOfDay(for: Date()) }
                .keyboardShortcut("t")
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        if !store.pending.isEmpty {
            ToolbarItem(placement: .navigation) {
                Button { showInvites.toggle() } label: {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.year))
                }
                .buttonStyle(.plain)
                .help("\(store.pending.count) invitation(s) awaiting response")
                .popover(isPresented: $showInvites, arrowEdge: .bottom) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                            InviteList(close: { showInvites = false })
                        }
                    }
                    .frame(width: 360, height: 440)
                    .background(Theme.bottomBg)
                    .environment(\.colorScheme, .dark)
                    .environment(store)
                }
            }
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.mode) {
                ForEach(CalMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .background {
                // ⌘1…⌘5 switch views.
                ForEach(Array(CalMode.allCases.enumerated()), id: \.offset) { i, m in
                    Button("") { model.mode = m }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                        .hidden()
                }
            }
        }
    }
}

/// Fantastical capture: 2000 px ↔ 1512 pt (1.3228 px/pt), measured in points.
enum Metrics {
    static let title: CGFloat = 26
    static let weekday: CGFloat = 12
    static let dayNumber: CGFloat = 14
    static let badge: CGFloat = 13
    static let badgeHeight: CGFloat = 21
    static let event: CGFloat = 12
    static let time: CGFloat = 10
    static let dot: CGFloat = 7
    static let line: CGFloat = 18      // pitch of event lines and bars
    static let bar: CGFloat = 16.5
    static let dayHeader: CGFloat = 30 // row top → first line
    static let todayBadge = Color(red: 0.48, green: 0.65, blue: 0.97)
}

private struct WindowQuickAdd: View {
    @Environment(CalendarStore.self) private var store
    @State private var quick = QuickAddModel()
    @State private var created: EKEvent?
    @FocusState private var focused: Bool
    let added: (DraftEvent) -> Void

    var body: some View {
        if let created {
            // Same popover turns into the new event's card for notes and invitees.
            EventInspector(event: created)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Meeting with Nathan tomorrow 9am at Cafe Lua", text: $quick.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit {
                        Task {
                            guard let d = await quick.finalDraft(), let e = store.create(d, in: nil) else { return }
                            quick.clear()
                            added(d)
                            created = e
                        }
                    }
                if let d = quick.draft { DraftPreview(draft: d, refining: quick.refining, choose: quick.choose) }
            }
            .padding(14)
            .frame(width: 360)
            .onAppear {
                focused = true
                quick.preferDomain = store.workDomain
            }
        }
    }
}

// MARK: - Event chips

/// Any event visual; click shows the same detail (join, RSVP, propose) as the menu bar list.
private struct EventChip<Label: View>: View {
    @Environment(CalendarStore.self) private var store
    let event: EKEvent
    @ViewBuilder let label: () -> Label
    @State private var show = false

    var body: some View {
        Button { show = true } label: { label().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .popover(isPresented: $show, arrowEdge: .trailing) {
                EventInspector(event: event).environment(store)
            }
    }
}

/// Fantastical-style "☁︎ 16°/7°" in a day's header, when the forecast covers that day.
private struct WeatherLabel: View {
    @Environment(CalendarStore.self) private var store
    let day: Date

    var body: some View {
        if let w = store.weather.day(day) {
            HStack(spacing: 4) {
                Image(systemName: w.symbol).symbolRenderingMode(.multicolor).font(.system(size: 13))
                Text("\(w.high)°/\(w.low)°").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .help("Forecast for \(store.weather.city)")
        }
    }
}

private func calColor(_ e: EKEvent) -> Color {
    Color(cgColor: e.calendar.cgColor ?? CGColor(gray: 0.5, alpha: 1))
}

private func shortTime(_ d: Date) -> String {
    Calendar.current.component(.minute, from: d) == 0
        ? d.formatted(.dateTime.hour())
        : d.formatted(.dateTime.hour().minute())
}

private struct EventLine: View {
    @Environment(CalendarStore.self) private var store
    let event: EKEvent

    var body: some View {
        let status = store.status(of: event)
        let hollow = status == .pending || status == .tentative
        let past = event.endDate < Date()
        EventChip(event: event) {
            HStack(spacing: 5) {
                Circle()
                    .strokeBorder(calColor(event), lineWidth: hollow ? 1.5 : 0)
                    .background(Circle().fill(hollow ? .clear : calColor(event).opacity(0.85)))
                    .frame(width: Metrics.dot, height: Metrics.dot)
                Text(event.title ?? "Untitled")
                    .lineLimit(1)
                    .strikethrough(status == .declined)
                Spacer(minLength: 2)
                Text(shortTime(event.startDate))
                    .font(.system(size: Metrics.time))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: Metrics.event))
            .opacity(past ? 0.5 : 1)
            .padding(.leading, 7)
            .padding(.trailing, 5)
            .frame(height: Metrics.line)
        }
    }
}

private struct SpanBar: View {
    let event: EKEvent
    let continues: Bool

    var body: some View {
        EventChip(event: event) {
            HStack(spacing: 4) {
                if !event.isAllDay && !continues {
                    Text(shortTime(event.startDate)).font(.system(size: Metrics.time)).foregroundStyle(.secondary)
                }
                Text(event.title ?? "Untitled").lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: Metrics.event))
            .padding(.horizontal, 8)
            .frame(height: Metrics.bar)
            .background(RoundedRectangle(cornerRadius: 3).fill(calColor(event).opacity(0.14)))
            .overlay(alignment: .leading) {
                if !continues { Rectangle().fill(calColor(event)).frame(width: 2.5) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .opacity(event.endDate < Date() ? 0.6 : 1)
        }
    }
}

// MARK: - Month / Quarter

private struct WeekdayHeader: View {
    let model: WindowModel
    var leading: CGFloat = 0

    var body: some View {
        let symbols = model.cal.shortStandaloneWeekdaySymbols
        HStack(spacing: 0) {
            Color.clear.frame(width: leading, height: 1)
            ForEach(0..<7, id: \.self) { i in
                Text(symbols[(model.cal.firstWeekday - 1 + i) % 7].uppercased())
                    .font(.system(size: Metrics.weekday, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.bottom, 4)
    }
}

private struct WeeksGrid: View {
    let model: WindowModel
    let weeks: Int
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            WeekdayHeader(model: model)
            Divider()
            GeometryReader { geo in
                let rowH = max(geo.size.height / CGFloat(weeks), compact ? Metrics.dayHeader + 3 * Metrics.line : Metrics.dayHeader + 4 * Metrics.line)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<weeks, id: \.self) { w in
                            WeekRow(model: model, start: model.add(.day, w * 7, model.range.lowerBound),
                                    height: rowH, month: compact ? nil : model.monthStart)
                        }
                    }
                }
                .scrollDisabled(rowH * CGFloat(weeks) <= geo.size.height + 1)
            }
        }
    }
}

private struct WeekRow: View {
    @Environment(CalendarStore.self) private var store
    let model: WindowModel
    let start: Date
    let height: CGFloat
    let month: Date?

    private let lineH = Metrics.line
    private let headerH = Metrics.dayHeader

    private struct Span { let event: EKEvent; let c0: Int; let c1: Int; let lane: Int }

    var body: some View {
        let cal = model.cal
        let days = (0..<7).map { model.add(.day, $0, start) }
        let spans = layoutSpans(days)
        let lines = max(1, Int((height - headerH - 2) / lineH))

        GeometryReader { g in
            let colW = g.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { c in
                        let here = spans.filter { $0.c0 <= c && c <= $0.c1 }
                        let offset = (here.filter { $0.lane < lines }.map(\.lane).max() ?? -1) + 1
                        let hidden = here.filter { $0.lane >= lines }.count
                        dayBox(days[c], offset: offset, hiddenSpans: hidden, lines: lines)
                            .frame(width: colW, height: height)
                    }
                }
                ForEach(spans.filter { $0.lane < lines }, id: \.event.rowID) { s in
                    SpanBar(event: s.event, continues: s.c0 == 0 && s.event.startDate < start)
                        .frame(width: CGFloat(s.c1 - s.c0 + 1) * colW - 3)
                        .offset(x: CGFloat(s.c0) * colW + 1.5, y: headerH + CGFloat(s.lane) * lineH + (lineH - Metrics.bar) / 2)
                }
            }
        }
        .frame(height: height)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
        .environment(\.calendar, cal)
    }

    /// Greedy lane packing for bars across the week, longest first so they stay on top.
    private func layoutSpans(_ days: [Date]) -> [Span] {
        let end = model.add(.day, 7, start)
        var seen = Set<String>()
        let events = days.flatMap { model.events(on: $0) }
            .filter { model.isSpanning($0) && seen.insert($0.rowID).inserted && $0.startDate < end }
        func col(_ d: Date) -> Int {
            let n = model.cal.dateComponents([.day], from: start, to: model.cal.startOfDay(for: d)).day!
            return min(6, max(0, n))
        }
        let items = events.map { e -> (EKEvent, Int, Int) in
            let last: Date = e.isAllDay ? e.endDate : e.endDate.addingTimeInterval(-1)
            return (e, col(e.startDate), col(max(e.startDate!, last)))
        }
        .sorted { ($0.2 - $0.1, $1.1) > ($1.2 - $1.1, $0.1) }

        var lanes: [[ClosedRange<Int>]] = []
        var out: [Span] = []
        for (e, c0, c1) in items {
            let lane = lanes.firstIndex { $0.allSatisfy { !$0.overlaps(c0...c1) } } ?? lanes.count
            if lane == lanes.count { lanes.append([]) }
            lanes[lane].append(c0...c1)
            out.append(Span(event: e, c0: c0, c1: c1, lane: lane))
        }
        return out
    }

    @ViewBuilder
    private func dayBox(_ day: Date, offset: Int, hiddenSpans: Int, lines: Int) -> some View {
        let cal = model.cal
        let timed = model.events(on: day).filter { !model.isSpanning($0) }
        let room = max(0, lines - offset)
        let overflow = timed.count + hiddenSpans > room
        let shown = overflow ? max(0, room - 1) : timed.count
        let outside = month.map { !cal.isDate(day, equalTo: $0, toGranularity: .month) } ?? false

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WeatherLabel(day: day).padding(.leading, 6)
                Spacer()
                dayNumber(day, outside: outside)
            }
            .frame(height: headerH)
            Color.clear.frame(height: CGFloat(offset) * lineH)
            ForEach(timed.prefix(shown), id: \.rowID) { EventLine(event: $0) }
            if overflow {
                Button("\(timed.count - shown + hiddenSpans) more…") { model.show(day, in: .day) }
                    .buttonStyle(.plain)
                    .font(.system(size: Metrics.event))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: lineH)
            }
            Spacer(minLength: 0)
        }
        .background(cal.isDateInWeekend(day) ? Color.primary.opacity(0.035) : .clear)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.show(day, in: .day) }
    }

    @ViewBuilder
    private func dayNumber(_ day: Date, outside: Bool) -> some View {
        let cal = model.cal
        let isToday = cal.isDateInToday(day)
        let first = cal.component(.day, from: day) == 1
        if isToday || first {
            Text(day.formatted(.dateTime.day().month(.abbreviated)))
                .font(.system(size: Metrics.badge, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: Metrics.badgeHeight)
                .background(Capsule().fill(isToday ? Metrics.todayBadge : Color(white: 0.45)))
                .padding(.trailing, 4)
        } else {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: Metrics.dayNumber))
                .foregroundStyle(outside ? .tertiary : .secondary)
                .padding(.trailing, 10)
        }
    }
}

// MARK: - Day / Week

private struct TimeGrid: View {
    @Environment(CalendarStore.self) private var store
    let model: WindowModel
    let days: [Date]

    private let hourH: CGFloat = 40
    private let gutter: CGFloat = 48

    private struct Block { let event: EKEvent; let start: Date; let end: Date; var col = 0; var cols = 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            allDayStrip
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { h in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(h == 0 ? "" : model.cal.date(bySettingHour: h, minute: 0, second: 0, of: days[0])!.formatted(.dateTime.hour()))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .frame(width: gutter - 8, alignment: .trailing)
                                        .offset(y: -7)
                                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                                }
                                .frame(height: hourH, alignment: .top)
                                .id(h)
                            }
                        }
                        GeometryReader { g in
                            let colW = (g.size.width - gutter) / CGFloat(days.count)
                            ForEach(days.indices, id: \.self) { i in
                                Rectangle().fill(Color.primary.opacity(0.08))
                                    .frame(width: 1, height: 24 * hourH)
                                    .offset(x: gutter + CGFloat(i) * colW)
                                ForEach(layout(days[i]), id: \.event.rowID) { b in
                                    let y = minutes(b.start, days[i]) / 60 * hourH
                                    let h = max(20, b.end.timeIntervalSince(b.start) / 3600 * hourH)
                                    let w = colW / CGFloat(b.cols)
                                    TimeBlock(event: b.event)
                                        .frame(width: w - 3, height: h - 2)
                                        .offset(x: gutter + CGFloat(i) * colW + CGFloat(b.col) * w + 2, y: y + 1)
                                }
                                if model.cal.isDateInToday(days[i]) {
                                    let y = minutes(Date(), days[i]) / 60 * hourH
                                    Rectangle().fill(Theme.year).frame(width: colW, height: 2)
                                        .offset(x: gutter + CGFloat(i) * colW, y: y)
                                    Circle().fill(Theme.year).frame(width: 8, height: 8)
                                        .offset(x: gutter + CGFloat(i) * colW - 4, y: y - 3)
                                }
                            }
                        }
                    }
                    .frame(height: 24 * hourH)
                }
                .onAppear {
                    let h = days.contains { model.cal.isDateInToday($0) } ? model.cal.component(.hour, from: Date()) - 1 : 7
                    proxy.scrollTo(max(0, h), anchor: .top)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { d in
                let today = model.cal.isDateInToday(d)
                HStack(spacing: 6) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(today ? Theme.accent : .secondary)
                    Text(d.formatted(.dateTime.day()))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(today ? .white : .primary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(today ? Theme.accent : .clear))
                    WeatherLabel(day: d)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.show(d, in: .day) }
            }
        }
        .padding(.bottom, 6)
    }

    private var allDayStrip: some View {
        let lists = days.map { d in model.events(on: d).filter { model.isSpanning($0) } }
        return HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: gutter - 8, alignment: .trailing)
                .padding(.trailing, 8)
            ForEach(days.indices, id: \.self) { i in
                VStack(spacing: 2) {
                    ForEach(lists[i].prefix(4), id: \.rowID) { SpanBar(event: $0, continues: true) }
                    if lists[i].count > 4 {
                        Text("\(lists[i].count - 4) more…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.vertical, lists.allSatisfy(\.isEmpty) ? 0 : 4)
        .frame(minHeight: 20)
    }

    private func minutes(_ d: Date, _ day: Date) -> CGFloat {
        CGFloat(d.timeIntervalSince(model.cal.startOfDay(for: day)) / 60)
    }

    /// Overlapping events share the column width; each cluster is sized independently.
    private func layout(_ day: Date) -> [Block] {
        let dayStart = model.cal.startOfDay(for: day)
        let dayEnd = model.add(.day, 1, dayStart)
        let blocks = model.events(on: day)
            .filter { !model.isSpanning($0) }
            .map { Block(event: $0, start: max($0.startDate, dayStart), end: min(max($0.endDate, $0.startDate.addingTimeInterval(900)), dayEnd)) }
            .sorted { $0.start < $1.start }

        var out: [Block] = []
        var cluster: [Block] = []
        var columnsEnd: [Date] = []
        func flush() {
            out += cluster.map { var b = $0; b.cols = columnsEnd.count; return b }
            cluster = []; columnsEnd = []
        }
        for var b in blocks {
            if let latest = columnsEnd.max(), b.start >= latest { flush() }
            if let free = columnsEnd.firstIndex(where: { $0 <= b.start }) {
                b.col = free; columnsEnd[free] = b.end
            } else {
                b.col = columnsEnd.count; columnsEnd.append(b.end)
            }
            cluster.append(b)
        }
        flush()
        return out
    }
}

private struct TimeBlock: View {
    @Environment(CalendarStore.self) private var store
    let event: EKEvent

    var body: some View {
        let color = calColor(event)
        let status = store.status(of: event)
        EventChip(event: event) {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(event.title ?? "Untitled").font(.system(size: 11, weight: .semibold)).lineLimit(2)
                            .strikethrough(status == .declined)
                        if MeetingLink.find(in: event) != nil {
                            Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    Text(TimeFormat.range(event.startDate, event.endDate))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4).padding(.vertical, 2)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(status == .pending ? 0.08 : 0.2)))
            .overlay {
                if status == .pending || status == .tentative {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .opacity(event.endDate < Date() ? 0.55 : 1)
        }
    }
}

// MARK: - Year

private struct YearGrid: View {
    let model: WindowModel

    var body: some View {
        let start = model.range.lowerBound
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 4), spacing: 16) {
                ForEach(0..<12, id: \.self) { m in
                    MiniMonth(model: model, month: model.add(.month, m, start))
                }
            }
            .padding(20)
        }
    }
}

private struct MiniMonth: View {
    let model: WindowModel
    let month: Date

    var body: some View {
        let cal = model.cal
        let gridStart = model.weekStart(month)
        VStack(alignment: .leading, spacing: 6) {
            Button { model.show(month, in: .month) } label: {
                Text(month.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(cal.isDate(month, equalTo: Date(), toGranularity: .month) ? Theme.year : .primary)
            }
            .buttonStyle(.plain)
            let symbols = cal.veryShortStandaloneWeekdaySymbols
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(0..<7, id: \.self) { i in
                        Text(symbols[(cal.firstWeekday - 1 + i) % 7])
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<6, id: \.self) { w in
                    GridRow {
                        ForEach(0..<7, id: \.self) { d in
                            cell(model.add(.day, w * 7 + d, gridStart))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ day: Date) -> some View {
        let cal = model.cal
        if !cal.isDate(day, equalTo: month, toGranularity: .month) {
            Color.clear.frame(height: 17)
        } else {
            let count = model.events(on: day).count
            let today = cal.isDateInToday(day)
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 10, weight: today ? .bold : .regular))
                .foregroundStyle(today ? .white : .primary)
                .frame(maxWidth: .infinity, minHeight: 17)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(today ? Theme.accent : Theme.accent.opacity(min(0.45, Double(count) * 0.07)))
                )
                .contentShape(Rectangle())
                .onTapGesture { model.show(day, in: .day) }
                .help(count == 0 ? "" : "\(count) event\(count == 1 ? "" : "s")")
        }
    }
}
