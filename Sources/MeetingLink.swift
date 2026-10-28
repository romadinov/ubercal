import AppKit
import EventKit

struct MeetingLink {
    enum Kind { case teams, meet, zoom, webex, facetime }
    let kind: Kind
    let url: URL

    var label: String {
        switch kind {
        case .teams: "Teams"
        case .meet: "Meet"
        case .zoom: "Zoom"
        case .webex: "Webex"
        case .facetime: "FaceTime"
        }
    }

    var longLabel: String {
        switch kind {
        case .teams: "Microsoft Teams Meeting"
        case .meet: "Google Meet"
        case .zoom: "Zoom Meeting"
        case .webex: "Webex Meeting"
        case .facetime: "FaceTime"
        }
    }

    @MainActor private static var cache: [String: MeetingLink?] = [:]
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Looks in URL, location and notes. Cached per event revision because Teams notes are long.
    @MainActor static func find(in e: EKEvent) -> MeetingLink? {
        let key = "\(e.calendarItemIdentifier)|\(e.lastModifiedDate?.timeIntervalSince1970 ?? 0)"
        if let hit = cache[key] { return hit }
        if cache.count > 500 { cache.removeAll() }
        let found = [e.url?.absoluteString, e.location, e.notes]
            .compactMap { $0 }
            .lazy
            .compactMap(firstLink(in:))
            .first
        cache[key] = found
        return found
    }

    private static func firstLink(in text: String) -> MeetingLink? {
        for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard var url = m.url else { continue }
            url = unwrapSafeLink(url)
            if let kind = kind(of: url) { return MeetingLink(kind: kind, url: url) }
        }
        return nil
    }

    /// Outlook rewrites links as https://*.safelinks.protection.outlook.com/?url=<real>
    private static func unwrapSafeLink(_ url: URL) -> URL {
        guard url.host?.hasSuffix("safelinks.protection.outlook.com") == true,
              let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let real = URL(string: inner) else { return url }
        return real
    }

    private static func kind(of url: URL) -> Kind? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            return path.contains("meetup-join") || path.hasPrefix("/meet") ? .teams : nil
        }
        if host == "meet.google.com" { return path.count > 1 ? .meet : nil }
        if host.hasSuffix("zoom.us") { return path.hasPrefix("/j/") || path.hasPrefix("/my/") ? .zoom : nil }
        if host.hasSuffix("webex.com") { return .webex }
        if host == "facetime.apple.com" { return .facetime }
        return nil
    }

    /// Opens in the native app when installed, skipping the browser hop.
    func open() {
        let ws = NSWorkspace.shared
        switch kind {
        case .teams:
            let s = url.absoluteString
            if let host = url.host, let r = s.range(of: host),
               let native = URL(string: "msteams:" + s[r.upperBound...]),
               ws.urlForApplication(toOpen: native) != nil {
                ws.open(native)
                return
            }
        case .zoom:
            let id = url.pathComponents.last ?? ""
            var native = URLComponents(string: "zoommtg://zoom.us/join")!
            native.queryItems = [URLQueryItem(name: "confno", value: id)]
                + (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "pwd" } ?? [])
            if url.path.hasPrefix("/j/"), let n = native.url, ws.urlForApplication(toOpen: n) != nil {
                ws.open(n)
                return
            }
        default:
            break
        }
        ws.open(url)
    }
}
