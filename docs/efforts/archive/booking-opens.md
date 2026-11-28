# Effort — Booking opens: the date, the reminder, the scout

**Status:** Dispatched · **Summary:** Implements [ADR-0056](../../decisions/0056-booking-opens.md). A to-book trip stop
gets a **booking opens** moment. The To Book sheet splits into Open now / Opens later / Needs an opening date, and the
header counts restaurants that need a date (S1). Jon's iPhone reminds him 30 minutes before booking opens (S2). Chat
supplies each restaurant's booking rule in the handoff, the rule is stored on the pool idea, and the app suggests the
opening with one-tap **Use** (S3, ADR-0056 D7–D9). The mini's scout (S4) and its findings (S5) are parked (D10).
**S1 adds `tripIdeas.bookingOpensAt` and S3 adds `ideas.bookingWindow`, so each owes a Production schema deploy.**

**Read first:** ADR-0056; ADR-0047 (booking status, the rollup, the To Book sheet); ADR-0052 D1, D2 and D8 (the helper,
the iCloud Drive transport, the export) before S4; jon-platform `docs/ios/persistence-and-sync.md` § Adding a synced
table or column before S1 and S3.

## Today

- `TripIdea` has `bookingStatus`, `bookingURL`, `confirmationNumber`, `partySize` and `pinnedDate`. The setters are
  `TripIdea.setBookingStatus` and `setBookingDetails` (`TripOperations.swift:780`, `:798`).
- `TripBookingRollup` (`GalavantSchema/TripBookingRollup.swift`) builds `toBook` / `decide` / `booked` from a
  `TripPlan`. `TripPlanningView.swift:106` draws the "N to book" pill, and `ToBookSheet` is in
  `TripPlanningSheets.swift:119`.
- The stop editor's Booking section is `BookingFields` over `BookingFieldsDraft` (`TripPlanningStaySheets.swift:69`,
  `TripPlanningDrafts.swift:109`). It's saved in `TripPlanningModel+Freeform.swift:61–71`.
- `CalendarTripTimeZone.resolve(day:…)` gives a day's time zone.
- There are no notifications and no URL or deep-link routing.
- jon-platform `install-mcp-helper` installs the `*MCP` package's single executable product.
- `GalavantChatExport` (`GalavantSchema/GalavantChatExport.swift`) is version 1, trip-level lines only. Its
  `Trip.encode` is hand-written.
- The inbox kind is `ChatInboxModel.kind` (`gvreturn`, `Galavant/ChatAccess/ChatInboxModel.swift:14`). The helper is
  `GalavantMCP/Sources/GalavantMCP`.

## S1 — The date

### Schema

- Append one migration, `Add bookingOpensAt to tripIdeas (ADR-0056)`, at the end of the registrations: a nullable
  `bookingOpensAt` column (a date, stored as the table's other dates are). Don't touch any shipped
  `registerMigration` body.
- Add `bookingOpensAt: Date?` to `TripIdea`, and a setter `TripIdea.setBookingOpensAt(_:stopID:in:)`.
- Add `tripIdeas bookingOpensAt` and its `sqlitedata_icloud_userModificationTime_bookingOpensAt` line to
  `cloudkit-expected-fields.txt`.

### Pure, in `GalavantSchema`, test-first

- `BookingOpening` (ADR-0056 D2), with
  `static func classify(resolved: ResolvedBooking, kind: IdeaKind?, opensAt: Date?, now: Date) -> BookingOpening?`.
  It returns `nil` when the row doesn't resolve to `.toBook`. Restaurant means `kind == .food`.
- `TripBookingRollup` gains `opening` on each `TripBookingItem` (stays are always `.notTracked`), plus
  `openNow`, `opensLater` (sorted by opening, then day) and `needsDate` views of `toBook`, and `needsDateCount`.
  `toBookCount` doesn't change. Build these in the existing single pass. Don't recompute per access, because of the
  TripPlan recompute hazard.
- Tests: each classification, including a past date as `openNow`, booked and not-needed stops ignored, non-food stops
  as `notTracked`, an undecided food stop absent from `needsDate`, and `opensLater` ordering.

### The app

- **Editor.** When the Booking section's resolved status is **To book** and the subject is a stop:
  - A **Booking opens** row: a toggle that reveals a date-and-time picker in the stop's day time zone (ADR-0056 D1),
    with the zone's abbreviation shown when it differs from the device's.
  - An **Already open** button that sets now.
  - Draft fields on `BookingFieldsDraft`, saved next to `setBookingDetails`.
  - Choosing Booked hides the row but doesn't clear the value.
- **Header pill.** "N to book · M need a date". Drop the second part at zero.
- **To Book sheet.** The *To book* section becomes three:
  - **Open now:** today's rows, with the Book link and Mark booked.
  - **Opens later:** "Opens Feb 14, 10:00 JST", with the Book link.
  - **Needs an opening date:** an **Add date** action opens the stop editor.

  Empty sections hide. *Decide* and *Booked* don't change.
- Formatting goes through one helper that takes the moment, the time zone and the device's zone, so S2's notification
  text uses the same function.

### Done when (S1)

- `scripts/check-drift.sh` is green, plus the headless app-target run, with its "Test run with N tests" line in the PR.
- The migration is appended, and `cloudkit-expected-fields.txt` has the two new lines.
- NEXT_UP's **Owed** stays the fixed pointer. The slice's `device-passes.md` line names the deploy: import
  `tripIdeas.bookingOpensAt` with `cktool`, then deploy the schema to Production before the TestFlight build.
- Device gate (iPhone, TestFlight): on a trip with a scheduled to-book dinner abroad, set Booking opens to a time
  tomorrow. The sheet shows it under Opens later with the destination's zone label. A second to-book dinner with no
  date makes the pill read "· 1 need a date". **Already open** moves it to Open now. Judge: is the three-way split
  clearer than one list?
- Closeout (ADR-0005 D16).

## S2 — Reminders

### Pure, in `GalavantSchema`, test-first

- `BookingReminderPlan.desired(items: [TripBookingItem] + trip context, now: Date, lead: Duration = .minutes(30),
  limit: Int = 50) -> [BookingReminder]`:
  - Each `BookingReminder` has `id` (`"booking-opens.<stopID>"`), `fireAt`, `title`, `body`, `tripID`.
  - It includes only `.opensLater` items, with `fireAt = max(opensAt − lead, now)`. The nearest `limit` by `fireAt`
    are kept.
  - Text follows ADR-0056 D3, through S1's formatting helper.
- `BookingReminderPlan.diff(desired:pending:) -> (add: [BookingReminder], remove: [String])`. A pending request whose
  fire date or text changed is removed and re-added.
- Tests: the lead time, a date inside the lead window firing now, a passed opening dropped, the cap, a booked stop
  removed, and a moved date replaced.

### The app

- `BookingReminderClient`, a swift-dependencies client (live over `UNUserNotificationCenter`, with a test value), with
  `authorize`, `pending`, `add` and `remove`. No singleton: the live value owns the center.
- **Settings → Booking reminders → "Booking reminders on this device",** stored in `@Shared(.appStorage)` and off by
  default. Put it next to Chat Access. Turning it on calls `authorize`. If permission is denied, the toggle turns back
  off with a note pointing to iOS Settings. Turning it off removes every `booking-opens.*` request.
- **Reconcile** while the switch is on: at launch, on foreground, on each `DatabaseChange.notifications` event
  (debounced), and when the switch changes. Read all live trips' rollups in one background pass, build `desired`,
  then apply `diff`. Follow the export's crash rules (ADR-0052 D8): off the main actor, with each trip's plan built
  once.
- **Tap:** a `UNUserNotificationCenterDelegate` selects the trip and presents its To Book sheet, through whatever state
  the root uses to select a trip today. Model it as a destination value, not a flag. A foreground notification shows
  as a banner.

### Done when (S2)

- check-drift green, plus the headless run.
- No schema change.
- Device gate (Jon's iPhone, TestFlight):
  1. Turn the switch on and allow notifications. Set a dinner's Booking opens to 35 minutes from now on the **iPad**.
  2. Within about 5 minutes the alert arrives on the iPhone, with the app closed.
  3. Tap it: the trip's To Book sheet opens.
  4. Mark another future reminder's stop booked: its pending request is gone (the Settings switch screen can show a
     pending count in Debug builds).

  Wendy's phone shows no prompt. Judge: is 30 minutes the right lead?
- Closeout.

## S3 — Rules from Chat

ADR-0056 D7–D9. Read `RecommendationHandoffContractInstructions.swift`, `RecommendationHandoff.swift` (`TripCandidate`),
`SeedReturn.swift`, `SeedPlan.swift` (`recordPlaceNotes` is the pattern for writing a place fact onto the idea), and
`RecommendationCandidateMatching.applyReevaluation` first.

### Schema

- Append one migration, `Add bookingWindow to ideas (ADR-0056 D8)`: a nullable `bookingWindow` text column. Don't
  touch any shipped `registerMigration` body.
- `Idea.bookingWindow: String?`, with a typed accessor like `weeklyHours` over `structuredHours`, and a setter
  `Idea.setBookingWindow(_:ideaID:in:)`.
- Add `ideas bookingWindow` and its `sqlitedata_icloud_userModificationTime_bookingWindow` line to
  `cloudkit-expected-fields.txt`.

### Pure, in `GalavantSchema`, test-first

- **`BookingWindowRule`** (ADR-0056 D5): `daysAhead`, `monthly`, `fixedDate`, `anyTime`, with `LocalTime` and
  `LocalDateTime` value types, all `Codable`.
- **`func opening(forMealOn: LocalDate, mealTime: LocalTime?, in: TimeZone, now: Date) -> Date?`:**
  - `daysAhead(n, t)`: the meal date minus n calendar days, at t (default 00:00), in the zone.
  - `monthly(d, k, t)`: day d of the month k months before the meal's month, at t.
  - `fixedDate`: that moment in the zone.
  - `anyTime`: `now`.

  Tests cover DST boundaries, month ends (meal on the 31st with `daysAhead(30)`), a year boundary, and an invalid
  `dayOfMonth` returning `nil`. One test is the Sweet Basil case: dinner Feb 9, 2027, `daysAhead(30)` at 09:00 in
  America/Denver gives Jan 10, 2027, 09:00 MST.
- **`BookingWindow`** (D8): `rule`, `timeZoneID`, `sourceURL`, `quote`, `source` (`.chat`; `.scout` is reserved for
  S4), and `foundAt`. It's `Codable` with a JSON round trip, and a stored value that won't decode reads as `nil`
  rather than throwing.
- **`BookingSuggestion`**: given a stop's resolved booking, its idea's window, the meal's date and the day's zone, the
  suggested `opensAt`. Use the window's `timeZoneID`, else the day's zone. It's `nil` when the stop isn't a to-book
  food stop or has a date already, and rule-only when the stop has no day.
- **The handoff field** (D7): `booking_window` decodes on `TripCandidate` and on seed places, into a `BookingWindow`
  with `source: .chat` and `foundAt` set at import. Unknown `kind`, a missing required number, or an unparseable time
  drop the field, not the place. Tests: each kind, a bad object dropped with the place kept, and a reply without the
  field.
- **The instructions** (D7): add `booking_window` to the candidate and seed field lists and to the example, and say when
  to give it: when `book_ahead` is true, research the restaurant's reservation release policy and give its rule, local
  zone, source URL and a short quote. Omit it rather than guess, and never give the opening date itself.
  `GV-CONTRACT` stays v2. Update the snapshot or contract tests that pin this text.
- **Writing it** (D8): `SeedPlan` writes the window onto the idea next to `recordPlaceNotes`, accepting a candidate does
  the same, and `applyReevaluation` writes it onto the linked stop's idea. Present replaces; absent never clears.
  Tests for each path.

### The app

- **Stop editor** (`BookingFields`): when the Booking opens row shows and a suggestion exists, a line under the toggle
  reads "Chat: 30 days ahead at 9:00 MT → Opens Jan 10, 9:00 AM MST" with **Use**. Use sets `hasOpeningDate` and
  `openingDate`, and Save writes them as with any edit. Format the moment through S1's `BookingOpeningFormat`, and
  describe the rule through one helper that S5 can reuse. **Source** opens `sourceURL` in the in-app browser. With no
  window, show the stop's `rationaleVisit` there, as secondary text that can be expanded.
- **To Book sheet**: a *Needs an opening date* row with a suggestion shows it with **Use**, which writes
  `bookingOpensAt` through S1's setter at once, so the row moves to Opens later (and S2 schedules its reminder). The
  pill's count is unchanged until Use.
- **Idea detail**: the window shows with the place's facts, as "Booking: 30 days ahead at 9:00 MT · source".

### Done when (S3)

- check-drift green, plus the headless run with its "Test run with N tests" line in the PR.
- The migration is appended, and `cloudkit-expected-fields.txt` has the two new lines. The slice's `device-passes.md`
  line names the deploy: import `ideas.bookingWindow` with `cktool`, then deploy to Production before the TestFlight
  build.
- Device gate (iPad or iPhone, TestFlight): in the Vail trip's Chat conversation, re-paste the project instructions
  and re-evaluate the trip's dinners. Review and apply. Then:
  1. Sweet Basil's editor shows "30 days ahead at 9:00 MT → Opens Jan 10, 9:00 AM MST", and **Use** then Save moves it
     to Opens later.
  2. Another dinner with a rule shows **Use** in the To Book sheet's *Needs an opening date* section, and one tap moves
     it.
  3. A dinner without a rule shows its Visit note under Booking opens.

  Judge: did Chat return rules for most book-ahead dinners, and were they right? That answer decides whether the scout
  (S4) resumes.
- Closeout.

## S4 — The scout

*Parked (ADR-0056 D10) until S3 has been used on a real trip. If it resumes: it targets only ideas with no
`bookingWindow`; `BookingWindowRule` and its arithmetic already exist from S3, so drop those bullets below; and an
accepted finding (S5) also writes the idea's `bookingWindow` with `source: .scout`.*

Code lands in this repo: `GalavantSchema`, a new `GalavantScout/` package, and `scripts/install-scout`. Nothing goes in
jon-platform, and `GalavantMCP/` and `install-mcp-helper` don't change.

### Pure, in `GalavantSchema`, test-first

- `BookingWindowRule` (ADR-0056 D5): `daysAhead`, `monthly`, `fixedDate`, `anyTime`, with `LocalTime` and
  `LocalDateTime` value types, all `Codable`.
- `func opening(forMealOn: LocalDate, mealTime: LocalTime?, in: TimeZone, now: Date) -> Date?`:
  - `daysAhead(n, t)`: the meal date minus n calendar days, at t (default 00:00), in the zone.
  - `monthly(d, k, t)`: day d of the month k months before the meal's month, at t.
  - `fixedDate`: that moment in the zone.
  - `anyTime`: `now`.

  Tests cover DST boundaries, month ends (meal on the 31st with `daysAhead(30)`), a year boundary, and an invalid
  `dayOfMonth` returning `nil`.
- **Export.** `GalavantChatExport.Trip.bookingTargets: [BookingTarget]?`, encoded only when non-empty and decoded with
  `decodeIfPresent`. `version` stays 1.
  - `BookingTarget`: `stopID`, `ideaID`, `title`, `website`, `bookingURL`, `locality`, `mealDate` (yyyy-MM-dd),
    `mealTime`, `timeZoneID`.
  - Built from S1's `needsDate`, and only for stops with a day: a dayless stop has no meal date.
  - Tests: a round trip, an older export with no key, and an older decoder ignoring the key.
- **`.gvbooking` file:** `BookingFindings` with `runID`, `ranAt`, and `findings: [Finding]`. A finding has `stopID`,
  `tripID`, `rule`, `opensAt`, `platform`, `sourceURL`, `quote` and `confidence`.
- **`scout.json`:** `ScoutStatus` with `ranAt`, `targets`, `found`, `notFound`, `cached` and `firstError`.
- Both formats are versioned and round-trip tested.

### The helper, `GalavantScout/`

- A new macOS-only package beside `GalavantMCP/`, with one executable product, **`galavant-scout`**. It depends on
  `GalavantLibrary`, `ChatAccessKit`, `WebExtractorKit` and `LLMClientKit`, and declares each one it uses. It's not a
  second product in `GalavantMCP/`, because `install-mcp-helper` requires that package to have exactly one executable.
  It resolves the export and inbox folders through `ChatAccessKit` as `galavant-mcp` does, including `--variant dev`. One run:
  1. Read the newest export.
  2. Collect `bookingTargets` across trips.
  3. For each target, take the cache, or research it (ADR-0056 D5), then compute `opensAt`.
  4. Write `.gvbooking` if anything was found, then always write `MCP/Status/scout.json`.
  5. Exit.
- **Research** goes through a `BookingWindowResearcher` dependency. Live: `WebExtractorKit` fetches the booking URL
  and website, then `LLMClientKit` asks Anthropic with web search for a structured `BookingWindowRule`, plus platform,
  source URL, quote and confidence. Use the default frontier model the house configures. The model must answer
  through a tool or JSON schema, never prose. A response with no source URL counts as not found.
- **Cache:** `~/Library/Application Support/galavant-scout/cache.json`, keyed by idea ID: a rule for 30 days, or a
  not-found for 7. It also records, per stop, the last `opensAt` staged. A run stages only findings that are new or
  changed, so an unanswered finding isn't re-sent every night.
- **Politeness:** follow Bright Lights ADR-0003 D4, with at most one request per second per host. A challenge or 403
  counts as not found and is never retried within the run.
- **`--dry-run`** prints the targets and cache hits, and calls nothing.
- **Install:** a new `scripts/install-scout` builds the release product and installs `~/.local/bin/galavant-scout`. It
  also writes a user LaunchAgent, `com.jonphillips.galavant-scout`, which runs daily at 03:00 and logs to
  `~/Library/Logs/galavant-scout.log`. `--uninstall` removes both. It's idempotent, so rerunning it after a pull
  updates the binary.
- **OQ1–OQ3** (ADR-0056) are answered on the mini during this slice, and recorded in the PR and the ADR's open
  questions. If the key can't be read from the app's item (OQ1), the installer prompts once and stores a key under
  the `galavant-scout` service in the login keychain.

### Done when (S4)

- check-drift green, plus the headless run. `scripts/check-drift.sh` gains
  `swift test --package-path GalavantScout` beside its `GalavantMCP` line.
- No schema change.
- Tests: the researcher's test value drives an end-to-end run against a fixture export in a temporary folder. It
  writes the expected `.gvbooking` and `scout.json`, and a second run is served from the cache.
- Device gate (the mini): install, then run once by hand.
  - `scout.json` appears, with counts matching the restaurants that need a date.
  - At least one real restaurant's finding names a correct platform and source.
  - `launchctl print` shows the agent scheduled.
- Closeout.

## S5 — Findings in the app

*Parked with S4 (ADR-0056 D10).*

### The app

- **Reading the files.** `BookingFindingsModel` reads `.gvbooking` files through `ChatInboxFileClient` with a second
  `ChatInboxItemKind` (`gvbooking`), only while Chat Access is on. It also reads `MCP/Status/scout.json`.
  - A finding is offered only while its stop still classifies `.needsDate`. Otherwise it's spent.
  - When every finding in a file is used, dismissed or spent, the file is claimed into `Processed/`.
  - Dismissals are kept in a small device-local set keyed by stop ID and `opensAt`, so the same answer stays dismissed
    and a changed answer is offered again (ADR-0056 D6). An entry is dropped once its stop leaves `.needsDate`.
  - A newer file's finding for a stop replaces an older one.
- **To Book sheet.** A *Needs an opening date* row with a finding shows the ADR-0056 D6 line, with **Use** and
  **Dismiss**, and its source opens in the in-app browser. **Use all** goes in the section header when two or more
  findings are offered. Use writes `bookingOpensAt` through S1's setter, so S2's reconcile schedules the reminder.
- **Footer:** the scout state line from ADR-0056 D6, with the 48-hour warning tint.
- The pill's "need a date" count includes rows with a pending finding, with no separate count. The sheet is where to
  review them.

### Docs

- jon-platform `docs/always-on-mac.md`: a "What runs" row for `galavant-scout` (the headless-helper shape, nightly), a
  Permissions row (its iCloud Drive grant, per OQ3), and its setup step in the Galavant Phase 1 item. This is a small
  jon-platform PR, following `agent-collaboration.md` § Dispatches whose code lands in jon-platform.
- Galavant `docs/chat-access-setup.md`: a paragraph on the scout and its log.

### Done when (S5)

- check-drift green, plus the headless run.
- No schema change.
- Device gate (iPhone, TestFlight, after a nightly run on the mini):
  - The To Book sheet shows a finding on a restaurant that needs a date, with its source.
  - **Use** moves the restaurant to Opens later, and a reminder is pending.
  - **Dismiss** on another removes it, and it stays gone after the next nightly run.
  - The footer shows the run's age.
  - Judge: are the findings right often enough to trust the one-tap Use?
- Closeout.

## Out of scope

As ADR-0056: no availability watching, no logins, no auto-booking, no stays, no reminders beyond the opening.
