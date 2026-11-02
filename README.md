# Ubercal

A lean menu bar calendar for macOS, modelled on Fantastical. It reads and writes through the
system Calendar (EventKit), so any account added in Calendar.app (Google, Exchange, iCloud) works
without its own connector.

- Menu bar popover: month grid, agenda that opens on the current or next meeting, Join buttons for Teams, Meet, Zoom and Webex
- Natural-language quick add ("Meeting with Nathan at 9am on Nov 4 in Telstra Tower"), with invitees resolved from Contacts and past meeting participants
- Event card: edit details and notes, add invitees, accept / maybe / decline with a comment, propose a new time
- Unanswered invitations list
- Full window with Day / Week / Month / Quarter / Year views and a daily weather forecast (Open-Meteo)

Requires macOS 26 or later.

## Outlook-only accounts (OWA)

Some tenants allow no client but Outlook: the account never reaches the system Calendar, and the admin
may also cap calendar publishing and sharing at busy-only and block creating an app registration — so
there's no OAuth or feed that carries real event detail. For such an account Ubercal shows a read-only
**OWA** calendar by reading Outlook on the web (`outlook.office.com`) through a browser session you are
already signed in to, as yourself. Because it reads what you see in the approved app, it shows real
detail — titles, times, organiser — not just busy blocks. Nothing is written to any local calendar.

It reuses the signed-in [agent-browser](https://www.npmjs.com/package/agent-browser) session that
[Jinnie](https://github.com/romadinov/Jinnie) keeps for Outlook (session `jinnie-outlook`, a persistent
Chrome profile), so there is no second sign-in. Install agent-browser once
(`npm i -g agent-browser && agent-browser install`) and sign in to Outlook in that session.

Gear menu › **OWA Calendar** › **Enable OWA Calendar**. OWA events then appear in the agenda, month and
window views and search, in Outlook blue. It is **read-only** — RSVP, creating and editing happen in
Outlook (each card has an **Open Outlook** button). The reader only opens pages and takes snapshots; it
never clicks, types or changes anything. When the shared session's sign-in expires, the menu shows
**Sign In to Outlook…** (a visible window; signing in re-authenticates both Ubercal and Jinnie).

## Build

```sh
./build.sh           # build/Ubercal.app
./build.sh install   # also copy to /Applications and launch
./release.sh         # Developer ID-signed zip, published as a GitHub release
```

Ubercal uses a few private EventKit methods (RSVP, propose new time, adding invitees), called
only after a `responds(to:)` check.
