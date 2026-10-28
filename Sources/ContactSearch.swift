import Contacts

/// Looks people up in the Mac's Contacts so "with Nathan" can become an invitee.
enum ContactSearch {
    struct Person: Hashable, Identifiable {
        let name: String
        let email: String
        var id: String { email }
    }

    private static let store = CNContactStore()
    private static let keys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    static var authorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    /// People from your meetings (organisers and attendees), with how often they appear.
    /// Covers colleagues who live only in the company directory, not in Contacts.
    @MainActor static var calendarPeople: [(person: Person, count: Int)] = []

    static var undetermined: Bool { CNContactStore.authorizationStatus(for: .contacts) == .notDetermined }

    static func requestAccess() async -> Bool {
        (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// Everyone matching the name, one entry per email address. Addresses on `preferDomain`
    /// (your work domain) come first so "Nathan" resolves to the colleague, not a namesake.
    @MainActor static func search(_ query: String, preferDomain: String? = nil, limit: Int = 6) -> [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let ql = q.lowercased()

        // Meeting people first: they're who you actually invite. Match a word of the name or the
        // start of the address ("kate" → kate@ideahelix.com).
        var scored: [(Person, Int)] = calendarPeople.compactMap { entry in
            let p = entry.person
            let words = p.name.lowercased().split(whereSeparator: { !$0.isLetter })
            let hit = words.contains { $0.hasPrefix(ql) } || p.name.lowercased().hasPrefix(ql) || p.email.lowercased().hasPrefix(ql)
            return hit ? (p, entry.count) : nil
        }
        if authorized {
            let contacts = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: q), keysToFetch: keys)) ?? []
            for c in contacts {
                let name = CNContactFormatter.string(from: c, style: .fullName) ?? q
                for e in c.emailAddresses { scored.append((Person(name: name, email: e.value as String), 0)) }
            }
        }
        let domain = preferDomain.map { "@" + $0.lowercased() }
        scored.sort { a, b in
            let da = domain.map { a.0.email.lowercased().hasSuffix($0) } ?? false
            let db = domain.map { b.0.email.lowercased().hasSuffix($0) } ?? false
            return da != db ? da : a.1 > b.1
        }
        var seen = Set<String>()
        return scored.map(\.0).filter { seen.insert($0.email.lowercased()).inserted }.prefix(limit).map { $0 }
    }
}
