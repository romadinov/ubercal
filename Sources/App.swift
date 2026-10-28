import Contacts
import EventKit
import SwiftUI

@main
struct UbercalApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store = CalendarStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Ubercal", id: "main") {
            MainWindow()
                .environment(store)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1512, height: 888)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// The menu bar label is always alive, so it hands the window opener to the app delegate.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    let store: CalendarStore

    var body: some View {
        Image(nsImage: Self.icon(day: store.cal.component(.day, from: store.today)))
            .task {
                AppDelegate.openMain = {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                if UserDefaults.standard.bool(forKey: "openWindow") { AppDelegate.openMain?() }
                if let path = UserDefaults.standard.string(forKey: "dumpCalendars") {
                    try? await Task.sleep(for: .seconds(2))
                    AppDelegate.dumpCalendars(store, to: path)
                }
                if let spec = UserDefaults.standard.string(forKey: "inviteTest") {
                    try? await Task.sleep(for: .seconds(2))
                    AppDelegate.inviteTest(store, spec: spec)
                }
                if let path = UserDefaults.standard.string(forKey: "popoverSnapshot") {
                    try? await Task.sleep(for: .seconds(2))
                    AppDelegate.render(PopoverView().environment(store), size: NSSize(width: 320, height: 650), to: path)
                }
                if let path = UserDefaults.standard.string(forKey: "inspectorSnapshot") {
                    try? await Task.sleep(for: .seconds(2))
                    AppDelegate.snapshotInspector(store, to: path)
                }
                if let path = UserDefaults.standard.string(forKey: "snapshot") {
                    try? await Task.sleep(for: .seconds(3))
                    AppDelegate.snapshot(to: path)
                }
            }
    }
}

extension MenuBarLabel {
    /// Fantastical-style glyph: a filled rounded square with the day number knocked out.
    /// Template image, so it follows the menu bar's light/dark tint.
    static func icon(day: Int) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 0.5), xRadius: 3.5, yRadius: 3.5).fill()
            let text = "\(day)" as NSString
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let t = text.size(withAttributes: attrs)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(at: NSPoint(x: (rect.width - t.width) / 2, y: (rect.height - t.height) / 2 + 0.5), withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openMain: (() -> Void)?

    /// Debug aid (`-snapshot /path.png`): renders the main window to a PNG and logs the
    /// traffic-light geometry, which is a fixed system size to calibrate layout against.
    @MainActor static func snapshot(to path: String) {
        guard let win = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
              let view = win.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { win.standardWindowButton($0)?.frame }
            .map { "\($0.origin.x),\($0.origin.y) \($0.width)x\($0.height)" }
        try? "window \(win.frame.size) scale \(win.backingScaleFactor)\nbuttons \(buttons)\n"
            .write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    }

    /// Renders a view offscreen at 2× so it can be compared pixel-for-pixel with Retina captures.
    @MainActor static func render<V: View>(_ view: V, size: NSSize, to path: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        // Give onAppear work (e.g. scroll-to-now) a moment before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            host.layoutSubtreeIfNeeded()
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            _ = win
        }
    }

    /// Debug aid (`-inspectorSnapshot /path.png`): renders the event popover for an upcoming
    /// meeting with invitees, since popovers can't be captured from outside.
    @MainActor static func snapshotInspector(_ store: CalendarStore, to path: String) {
        let now = Date()
        let events = store.fetchEvents(now..<now.addingTimeInterval(14 * 86400))
        guard let e = events.first(where: { ($0.attendees?.count ?? 0) > 1 && MeetingLink.find(in: $0) != nil })
                ?? events.first(where: { ($0.attendees?.count ?? 0) > 1 }) ?? events.first else { return }
        let host = NSHostingView(rootView: EventInspector(event: e).environment(store).environment(\.colorScheme, .light))
        host.frame.size = host.fittingSize
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        win.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Debug aid (`-inviteTest "create|<email>|<out>"` or `"delete|<eventIdentifier>|<out>"`):
    /// end-to-end check that invitations created through Ubercal reach the invitee.
    @MainActor static func inviteTest(_ store: CalendarStore, spec: String) {
        let parts = spec.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        var out = ""
        if parts[0] == "create", let domain = store.workDomain,
           let cal = store.writableCalendars.first(where: { $0.title.hasSuffix("@" + domain) }) {
            var d = DateComponents(); d.weekday = 3; d.hour = 9
            let start = store.cal.nextDate(after: Date().addingTimeInterval(86400 * 2), matching: d, matchingPolicy: .nextTime)!
            let draft = DraftEvent(title: "Ubercal invite test", start: start, end: start.addingTimeInterval(1800), allDay: false, location: nil,
                                   invitees: [InviteeChoice(query: parts[1], options: [ContactSearch.Person(name: parts[1], email: parts[1])], selectedIndex: 0)])
            if let e = store.create(draft, in: cal) {
                out = "created \(e.eventIdentifier ?? "?") start \(start)\nattendees " + (e.attendees ?? []).map(\.url.absoluteString).joined(separator: ", ")
            } else { out = "create failed: \(store.lastError ?? "")" }
        } else if parts[0] == "delete", let e = store.ek.event(withIdentifier: parts[1]) {
            store.delete(e)
            out = "deleted \(parts[1]) error=\(store.lastError ?? "none")"
        } else { out = "nothing done" }
        try? out.write(toFile: parts[2], atomically: true, encoding: .utf8)
    }

    /// Debug aid (`-dumpCalendars /path.txt`): what EventKit exposes, to diagnose missing calendars.
    @MainActor static func dumpCalendars(_ store: CalendarStore, to path: String) {
        let ek = store.ek
        var out = "access \(EKEventStore.authorizationStatus(for: .event).rawValue) hidden \(store.hiddenCalendarIDs.count)\n"
        for s in ek.sources {
            out += "SOURCE \(s.title) type=\(s.sourceType.rawValue) id=\(s.sourceIdentifier) cals=\(s.calendars(for: .event).count)\n"
        }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        for c in ek.calendars(for: .event) {
            let n = ek.events(matching: ek.predicateForEvents(withStart: start, end: end, calendars: [c])).count
            out += "CAL \(c.title) | \(c.source.title) | type=\(c.type.rawValue) hidden=\(store.hiddenCalendarIDs.contains(c.calendarIdentifier)) today=\(n)\n"
        }
        out += "pending \(store.pending.count): " + store.pending.map { $0.title ?? "" }.joined(separator: " | ") + "\n"
        out += "workDomain \(store.workDomain ?? "-")\n"
        let cn = CNContactStore()
        for c in (try? cn.containers(matching: nil)) ?? [] {
            let n = (try? cn.unifiedContacts(matching: CNContact.predicateForContactsInContainer(withIdentifier: c.identifier), keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor]).count) ?? -1
            out += "container \(c.name) type=\(c.type.rawValue) contacts=\(n)\n"
        }
        out += "contacts status \(CNContactStore.authorizationStatus(for: .contacts).rawValue)\n"
        for q in ["Kate", "Nathan"] {
            out += "contacts '\(q)': " + ContactSearch.search(q, preferDomain: store.workDomain).map { "\($0.name) <\($0.email)>" }.joined(separator: ", ") + "\n"
        }
        // Invitee API check on an unsaved event — never saved, so nothing is sent.
        if let cal = ek.calendars(for: .event).first(where: { $0.source.sourceType == .calDAV && $0.allowsContentModifications && $0.title.contains("@") && !$0.title.contains("gmail") }) {
            let e = EKEvent(eventStore: ek)
            e.calendar = cal
            e.title = "probe"; e.startDate = Date().addingTimeInterval(86400 * 30); e.endDate = e.startDate.addingTimeInterval(1800)
            out += "canInvite \(store.canInvite(e)) on \(cal.title)\n"
            store.addInvitee(e, name: "Probe Person", email: "probe@example.com", save: false)
            out += "attendees after add: " + (e.attendees ?? []).map { "\($0.url.absoluteString) current=\($0.isCurrentUser)" }.joined(separator: ", ") + "\n"
            out += "organizer: \(e.organizer?.url.absoluteString ?? "nil")\n"
            e.reset()
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Launching Ubercal again (Finder, Spotlight, Dock) opens the full window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.openMain?() }
        return true
    }
}
