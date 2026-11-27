# ADR-0056: When booking opens — a date on the stop, a reminder on Jon's phone, a scout on the mini

*Status: **proposed** — 2026-11-27, ratified by Jon merging this ADR's PR. Effort:
[`booking-opens`](../efforts/booking-opens.md). Extends [ADR-0047](0047-trip-booking-status.md) (booking status) with
the one fact it lacks: when a to-book stop *can* be booked. The scout follows [ADR-0052](0052-chat-access-over-mcp.md)
(a macOS-only helper, transport through Jon's iCloud Drive) and jon-platform `docs/always-on-mac.md` § What runs on the
mini. Holds ADR-0001 (no server), ADR-0003 (no ownership flags) and ADR-0004 (the model proposes, a human tap writes).
**Adds one synced column, `tripIdeas.bookingOpensAt`, so S1 owes a Production schema deploy.***

Summary: A trip stop gets a nullable **booking opens** moment. The To Book sheet sorts to-book rows into *open now*,
*opens later* and *needs an opening date*, and the trip header shows how many restaurants need a date. Jon's iPhone
reminds him **30 minutes before** booking opens, using a local notification and no server. Each night a `galavant-scout`
helper on the always-on mini looks up the booking window of each restaurant that has no date and stages what it finds.
One tap in the app accepts a finding.

## Context

Jon asked on 2026-11-27: "I'd like to have a date in restaurant listings of the date the restaurant is available to
reserve," with a reminder, and asked whether the mini should do the checking. Sought-after restaurants release tables
on a schedule: "30 days ahead at 10:00 Tokyo time", "the 1st of each month for the month after next". If you miss the
release, the table is gone.

What exists today:

- **Booking status per trip row** (ADR-0047): `bookingStatus`, `bookingURL`, `confirmationNumber`, `partySize` and
  `pinnedDate` on `TripIdea`, all resolved through `BookingStatus.resolve`. `TripBookingRollup` feeds the "N to book"
  pill and `ToBookSheet` (*To book / Decide / Booked*). Nothing records when booking opens.
- **No notifications of any kind.** The app has the `remote-notification` background mode for CloudKit and nothing
  else.
- **Galavant is iOS-only.** The Mac runs it as an iPad app. ADR-0052 D2 rejected running Galavant as a sync peer on
  the Mac. The mini already runs Galavant's `galavant-mcp` helper, which reads a derived export from, and stages files
  into, Jon's iCloud Drive container.

## Decision

### D1 — `bookingOpensAt` is a moment on the trip stop

`TripIdea.bookingOpensAt: Date?` is a new nullable synced column. It holds the first moment this stop can be booked,
stored as an absolute instant.

- **It belongs to the stop, not the pool idea.** As in ADR-0047 §1, the date depends on the meal's date: the same
  restaurant's opening date differs for each trip it's on. The restaurant's *rule* ("30 days ahead at 10:00") is a
  fact about the place, and only the scout's cache holds it (D5). A pool-level rule column can come later if hand entry
  turns out to repeat itself.
- **Stops only.** Stays and freeform stops don't get it in v1. Lodging rarely has release windows, and the column can
  be added to `TripStay` later.
- **A past value means "open now".** The editor's **Already open** button writes the current moment. That's how a
  restaurant that books any time leaves the "needs a date" count before it's booked.
- **Entered and shown in the meal's time zone,** which is the time zone of the stop's day
  (`CalendarTripTimeZone.resolve(day:…)`: day override, then day region, then trip centroid), falling back to the
  device's. "Opens Feb 14, 10:00 JST" carries its zone label whenever it differs from the device's.
- **Booking doesn't clear it.** Once the stop resolves to `.booked` or `.notNeeded`, the date is ignored: it isn't
  shown or counted, and nothing is scheduled for it. If the stop goes back to to-book, the date is still there.
- It's an additive column on a synced table, so existing rows read as `nil`, older builds ignore it, and the per-field
  merge keeps a peer on an older build from wiping it.

### D2 — "Needs an opening date" is a count Jon can see

A pure function in `GalavantSchema` classifies each to-book stop in the rollup by its opening:

```swift
public enum BookingOpening: Equatable, Sendable {
  case openNow                 // bookingOpensAt <= now
  case opensLater(Date)        // bookingOpensAt > now
  case needsDate               // nil, and the row is a restaurant
  case notTracked              // nil, and the row isn't a restaurant
}
```

- **A restaurant is a stop whose idea kind is `.food`.** Bars (`.drink`), tours and theater can carry a date by hand
  but aren't counted as missing one. Widening the count is a one-line change with a test.
- **Only stops that resolve to `.toBook` and fall under ADR-0047 §3 count.** That means scheduled, live, and not on
  a past day. Undecided food stops aren't counted, because ADR-0047's *Decide* group asks first whether they need
  booking at all.
- **Display.**
  - The trip header pill reads **"5 to book · 2 need a date"**. The second part hides when it's zero.
  - The To Book sheet's *To book* group splits into **Open now**, **Opens later** (soonest opening first), and
    **Needs an opening date**, the last holding the scout's findings (D6).
  - Rows in *Opens later* show "Opens Feb 14, 10:00 JST". An itinerary row's booking glyph is unchanged.

### D3 — Reminders are local notifications, on Jon's devices only

- **No server and no push.** CloudKit subscriptions fire when a record changes, not at a time of day. The app schedules
  `UNUserNotificationCenter` requests itself, and they fire while the app is closed. Local notifications need no new
  entitlement.
- **A device-local switch, off by default:** Settings → **Booking reminders on this device**, stored in device-local
  app storage, never synced. Turning it on asks for notification permission. Jon turns it on for his iPhone; Wendy's
  devices never ask. This isn't an ownership flag (ADR-0003), because the data is still shared and only this device's
  alerts change. Chat Access (ADR-0052 D2) uses the same pattern.
- **Fires 30 minutes before** `bookingOpensAt`. The lead time is a core constant. If the device first learns of a
  date less than 30 minutes before the opening, it notifies at once. Once the opening has passed, nothing is sent.
- **The schedule is computed, not edited.** A pure `BookingReminderPlan.desired(stops:now:lead:)` returns the requests
  that should exist, each identified by its stop ID. The app diffs that against what's pending and adds, replaces or
  removes to match. It reconciles at launch, on foreground, after each `DatabaseChange`, and when the switch changes.
  The nearest 50 are kept, under iOS's 64-request cap.
- **A date set on the iPad reaches the phone's schedule when the phone syncs** (CloudKit's background push, or the next
  open). Dates are set days ahead, so that's enough. The brief's device pass checks it.
- **Text:** "Booking opens in 30 min · Kikunoi" / "Dinner Thu Mar 14 · opens 10:00 Kyoto time". Tapping it opens that
  trip's To Book sheet.

### D4 — The scout is a macOS-only helper on the mini, beside `galavant-mcp`

`galavant-scout` is the one executable of a new macOS-only `GalavantScout/` package, a sibling of `GalavantMCP/`. It
shares the ADR-0052 D1 constraints: built from `GalavantSchema`, and outside the iOS package graph. It's a separate
package, not a second product in `GalavantMCP/`, because jon-platform's `install-mcp-helper` finds the helper as that
package's *one* executable (jon-platform ADR-0009 D2).

- **It writes files, never rows,** which is the "small headless helper" shape in `always-on-mac.md`. Galavant doesn't
  run on the Mac (ADR-0052 D2), and the "one process per database" rule holds.
- **A daily user LaunchAgent runs it at 03:00 local,** installed by Galavant's own `scripts/install-scout`.
  It holds no lease, because Jon's iCloud Drive container is the only place it can work, and only the mini installs it. On another Mac,
  where it isn't installed, nothing happens.
- **Input: the chat-access export.** Each trip gains an optional `bookingTargets` list: the D2 `needsDate` stops, with
  stop ID, idea ID, title, website, booking URL, locality, the meal's date and time, and the day's time-zone
  identifier (D1). The key is additive and optional, so the export's `version` stays 1, and an older helper ignores it. The
  export already needs Chat Access on Jon's iPhone and refreshes when the app backgrounds, so a stop scheduled today is
  in tonight's run.
- **Output:**
  - A staged **`.gvbooking`** file in `MCP/Inbox/`, a new `ChatInboxItemKind`, when a run finds anything.
  - A run status file, `MCP/Status/scout.json`, overwritten each run: when it ran, how many targets, found, not found,
    and the first error.

  An empty run writes only the status file.

### D5 — The model reads the rule, code computes the date

For each target, the scout:

1. **Checks its cache.** A rule found within the last 30 days for this idea is reused without a model call. A
   "not found" is retried after 7 days, not nightly. The cache is a JSON file in the helper's Application Support
   directory on the mini. It isn't synced, and it's safe to delete.
2. **Researches.** It fetches the booking URL and the website through `WebExtractorKit`, then asks a frontier model
   through `LLMClientKit`, with web search, using Jon's key. The model is asked for the restaurant's reservation
   release policy and has to answer in this shape:

   ```swift
   enum BookingWindowRule: Codable {
     case daysAhead(Int, releaseTime: LocalTime?)                     // "30 days ahead at 10:00"
     case monthly(dayOfMonth: Int, monthsAhead: Int, releaseTime: LocalTime?)  // "1st, for the month after next"
     case fixedDate(LocalDateTime)                                    // "March bookings open Feb 1, 10:00"
     case anyTime                                                     // books whenever; no window
   }
   ```

   Each answer carries the platform name (Tock, Resy, OMAKASE, the restaurant's own page), a source URL, a short quote,
   and a confidence. An answer with no source URL is dropped.
3. **Computes** `bookingOpensAt` with a pure `BookingWindowRule.opening(forMealOn:mealTime:in:)` in `GalavantSchema`.
   This is unit-tested across time-zone and month-boundary cases, and the model never does the date arithmetic.
   `anyTime` yields the run's own moment, so it reads as open now.
4. **Stays polite,** following Bright Lights ADR-0003 D4: it honors robots.txt, waits at least a second between
   requests, never logs in, and never gets around a challenge or a 403. It never books anything.

### D6 — A finding is a suggestion, and one tap accepts it

In the To Book sheet, each *Needs an opening date* row that has a finding shows:

> **Found:** opens Feb 14, 10:00 JST · 30 days ahead on Tock · *source* — **Use** · **Dismiss**

- **Use** writes `bookingOpensAt`. Only then does the row leave the count and get a reminder. **Use all** on the
  section header accepts every finding at once.
- **Dismiss** drops that finding. A rejected finding isn't offered again for that stop unless the scout's answer
  changes.
- **The tap is the write,** as ADR-0004 and ADR-0052 require. A misread release time is the costliest kind of mistake
  here, because it moves the reminder, and the source and quote are one tap away.
- **Findings reach only Jon's devices.** The inbox is in his iCloud Drive (ADR-0052 D2). Wendy sees an accepted date
  once it syncs, and she gets no reminder unless she turns the switch on.
- **The sheet's footer shows the scout's state**, read from `scout.json`: "Mac mini checked 6 h ago · 2 found · 1 not
  found". If no status file exists, the footer reads "The Mac mini hasn't checked yet". If the last run is more than
  48 hours old, the line turns to a warning tint. That follows `always-on-mac.md`: nothing happens while the mini
  isn't running, so the app says so.

## Why this and not the alternatives

- **An iMessage from the mini instead of a notification.** The mini already sends iMessages (jon-platform ADR-0010
  D3). But a notification can be tapped to open the booking, and needs no Automation grant and no lease. It also keeps
  working when the mini is off, because the date is already on the phone. The mini finds dates; the phone gives the
  alert.
- **The mini applies findings directly.** It can't, because it has no database (D4). The alternative would be
  auto-accepting high-confidence findings in the app, which was rejected for v1 (D6). Revisit after dogfood if every
  finding is accepted unchanged.
- **Running Galavant on the mini as a windowless sync peer,** as Bright Lights does. ADR-0052 D2 already rejected this
  for Galavant, and the scout needs only read access to an export and a write into the inbox.
- **A pool-level `Idea.bookingWindowRule` column.** It would save re-research across trips, but the scout's cache does
  that at no schema cost. Revisit if hand entry is common.
- **Real push via a server or CloudKit subscription.** That would break the no-server rule, or fire on changes rather
  than at a time of day.

## Consequences

- One Production deploy: `tripIdeas.bookingOpensAt` (S1).
- The export gains an optional key and the inbox a second item kind, and `ChatAccessKit` needs no change.
- The scout spends Jon's frontier tokens nightly, but only on restaurants that need a date and aren't cached. In
  practice that's a handful each time a trip gets new dinners.
- The mini's setup gains a step, as do `always-on-mac.md`'s "What runs" and "Permissions" tables. The scout's binary
  may need its own Files and Folders → iCloud Drive grant (OQ3).
- If the mini is off, reminders for accepted dates still fire. Only new findings stop.

## Out of scope

- Watching for open tables or cancellations, and booking anything automatically.
- Logging in to Resy, Tock, OpenTable or similar.
- Opening dates for stays, and a "needs a date" count for kinds other than `.food`.
- Reminders for anything other than an opening, such as a cancellation deadline or a deposit.

## Slices

1. **S1 — The date.** Migration and column, editor field, `BookingOpening`, To Book grouping, header count. Owes the
   schema deploy.
2. **S2 — Reminders.** The device switch, `BookingReminderPlan`, reconcile, and tapping a notification to open the To
   Book sheet.
3. **S3 — The scout.** Export `bookingTargets`, `BookingWindowRule` and its date arithmetic, the `GalavantScout/`
   package, cache, `.gvbooking` and `scout.json`, and `scripts/install-scout` with the LaunchAgent.
4. **S4 — Findings in the app.** Reading `.gvbooking` and `scout.json`, Use / Use all / Dismiss, the footer, and the
   mini's setup step in jon-platform `always-on-mac.md`.

## Open questions (answered in S3, on the mini)

- **OQ1 — Can a LaunchAgent CLI read Jon's model key?** The app's key lives in an iCloud Keychain item that a
  differently signed binary may not be able to read. Fallback: the installer stores a key for the helper in the
  mini's login keychain under the helper's own service name, once, in person.
- **OQ2 — Does `RenderedDOMFetcher` work from a launchd CLI?** WebKit wants an app run loop. Fallback: plain fetch
  plus the model's web search, which covers most booking-policy pages.
- **OQ3 — Which grants does the scout need on macOS 27.3?** It reads and writes the Galavant container in iCloud
  Drive, likely needing its own Files and Folders → iCloud Drive grant, given in person at setup.
