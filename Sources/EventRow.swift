import EventKit
import SwiftUI

struct EventRow: View {
    @Environment(CalendarStore.self) private var store
    let event: EKEvent
    let day: Date
    var showDate = false
    @State private var inspecting = false

    var body: some View {
        let now = Date()
        let past = event.endDate < now && !event.isAllDay
        let link = MeetingLink.find(in: event)
        let status = store.status(of: event)
        let color = Color(cgColor: event.calendar.cgColor ?? CGColor(gray: 0.5, alpha: 1))

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .strokeBorder(color, lineWidth: status == .pending || status == .tentative ? 2 : 0)
                    .background(Circle().fill(status == .pending || status == .tentative ? .clear : color))
                    .frame(width: 10, height: 10)
                    .padding(.top, 2)
                    .opacity(past ? 0.45 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(timeText).font(.system(size: 11, weight: .semibold))
                        if let link { Image(systemName: link.kind == .teams ? "person.2.fill" : "video.fill").font(.system(size: 10)) }
                        if status == .pending { badge("INVITE", Theme.year) }
                    }
                    .foregroundStyle(Color(white: past ? 0.5 : 0.85))

                    Text(event.title ?? "Untitled")
                        .font(.system(size: 13, weight: past ? .regular : .medium))
                        .foregroundStyle(past ? Color(white: 0.55) : .white)
                        .strikethrough(status == .declined)
                        .lineLimit(1)

                    if let sub = subtitle(link) {
                        Text(sub).font(.system(size: 11)).foregroundStyle(Color(white: 0.5)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)

                if let link, event.endDate > now {
                    Button { link.open() } label: {
                        Text("Join")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(isSoon ? Theme.accent : Color(white: 0.3)))
                    }
                    .buttonStyle(.plain)
                    .help("Join \(link.label) meeting")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { inspecting = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3.5)
        .background(inspecting ? Color(red: 0.72, green: 0.85, blue: 0.9).opacity(0.85) : .clear)
        .popover(isPresented: $inspecting, arrowEdge: .leading) {
            EventInspector(event: event)
                .environment(store)
        }
    }

    private var isSoon: Bool {
        let now = Date()
        return event.startDate.addingTimeInterval(-10 * 60) <= now && event.endDate > now
    }

    private var timeText: String {
        if event.isAllDay { return showDate ? "\(dateText) · all-day" : "all-day" }
        let t = TimeFormat.range(event.startDate, event.endDate)
        return showDate ? "\(dateText) · \(t)" : t
    }

    private var dateText: String {
        event.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func subtitle(_ link: MeetingLink?) -> String? {
        guard let loc = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty else {
            return link.map { "\($0.label) meeting" }
        }
        // Teams puts the whole join URL in the location; show something readable instead.
        if loc.hasPrefix("http") { return link.map { "\($0.label) meeting" } ?? loc }
        return loc
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color))
    }
}
