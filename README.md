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

## Build

```sh
./build.sh           # build/Ubercal.app
./build.sh install   # also copy to /Applications and launch
./release.sh         # Developer ID-signed zip, published as a GitHub release
```

Ubercal uses a few private EventKit methods (RSVP, propose new time, adding invitees), called
only after a `responds(to:)` check.
