# M5 (Polish & distribution) — execution briefs

Paste the relevant brief into a **fresh session** to execute one M5 slice. Same
contract as `docs/M6-EXECUTION.md`: each is self-contained, names the in-tree
precedent to clone, the **skill checkpoints** for past-cutoff APIs, where tests go,
and the done-criteria. Open the session with the slice's **suggested model**.

These three are the "make daily two-person use good" band of M5 (ROADMAP), sequenced
to ride alongside the TestFlight / two-device dogfooding push (which is the real M5
spine — `both phones run it daily`). They are **independent of the paused M6 AI
thread**.

**Build order (recommended): sync health → pinned reservations → calendar export.**
Sync health is the smallest and de-risks the dogfooding you're about to lean on
(you'll finally *know* whether two-device sync is live vs. silently local-only).
Pinned reservations lays the absolute-date foundation that calendar export then wants
to honor. All three are largely parallel — the order is about payoff, not hard deps.

---

## Shared guardrails (apply to every brief)

Identical to `docs/M6-EXECUTION.md` → "Shared guardrails" — read that block. In
short: read `CLAUDE.md` / `docs/STYLE.md` / the cited ADR / `~/code/jon-platform/AGENTS.md`
first; `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`;
XcodeGen owns the project (edit `project.yml`, `xcodegen generate`, declare every
imported package product as a dep); **tests live in the SPM package, never the app
target** (`galavant-app-target-untestable`); CloudKit rules (UUID PKs, one real FK
per synced record — ADR-0007, additive migrations in `Database.swift`, register new
tables with the SyncEngine); invoke **`pfw-sqlite-data`** / **`pfw-structured-queries`**
rather than recalling query syntax; verify `swift test --package-path GalavantLibrary`
+ `xcodebuild build` + `swiftlint lint --strict` before declaring done; **don't commit
or open PRs unless asked** (branch off `main` first if you do).

---

## M5-sync — sync health surface · **Opus** (SQLiteData `SyncEngine` state API is past-cutoff)

**Goal:** end silent sync degradation. Surface, in Settings, whether CloudKit sync is
**live, local-only, or broken** — and why. For a two-person household this is the
difference between "we share a pool" and "we each have a private pool and don't know
it" (ROADMAP M5: *silent degradation is fine for dev, not for two-person use*).

**This is not a from-scratch slice — the state already exists, ephemerally.**
`GalavantSchema/GalavantCloudSync.swift` already computes everything the surface needs,
but throws it away as one-shot return values:
- `StartResult` — `.disabled` / `.unavailable(String)` / `.started` / `.failed(String)`
  (from `startIfManuallyEnabled()`, called once at launch in `GalavantApp`/`SceneDelegate`).
- `isManuallyEnabled()` — the user gate (sync is off until manually enabled).
- `CKAccountStatus` + `syncDescription` — the iCloud-account reason string.
- `pendingRecordZoneChangeCount(in:)` — outbound rows not yet pushed (the "still
  uploading" / "stuck" signal; already used for the share-extension redrain race).

**Slices:**
1. **Pure `SyncHealth` value type + reducer** in `GalavantSchema` (the testable core).
   A `SyncHealth` struct (gate on/off, `CKAccountStatus`, engine started?, pending
   count, last error) → a `displayStatus` computed enum:
   `.disabled` / `.localOnly(reason:)` / `.syncing(pending:)` / `.upToDate` / `.error(String)`.
   This is the same "total conversion" shape as `Certainty`/`Schedule` — a pure
   function from raw signals to a display state, fully unit-tested (every account
   status → the right reason; pending>0 → `.syncing`; gate-off → `.disabled`). No
   CloudKit import in the reducer — feed it plain values.
   > **Cross-app seam (don't extract yet — just keep it clean):** this reducer is
   > destined for `jon-platform` (every SQLiteData+CloudKit app wants the same "am I
   > actually syncing?" surface). Keep it **domain-free** — it takes raw sync signals
   > and knows nothing about `Idea`/`Trip`/travel parties — so the later lift is a
   > rename-and-move, like `WebExtractorKit`/`GalavantAI`. No premature package.
2. **App-side `SyncHealthModel`** (`@Observable`, in the app's `Settings/`) that
   gathers the live signals and refreshes: on appear, on scene `.active` (reuse the
   existing scene hooks that already drive the redrain), and on `DatabaseChange`. It
   calls `accountStatus()` + `pendingRecordZoneChangeCount` + the gate, folds them into
   `SyncHealth`, and exposes `displayStatus`. **Skill checkpoint — the one real
   unknown:** does SQLiteData's `SyncEngine` expose an *observable* running state (or a
   metrics/last-error stream) beyond `start()`/`stop()`? Invoke **`pfw-sqlite-data`**
   and check current docs before assuming; if it only offers start/stop, derive
   "started" from the last `StartResult` you persist at launch rather than inventing a
   flag. Don't guess the API from memory.
3. **The Settings row.** A status row at the top of `SettingsScreen` (above the
   existing Sharing section) — a colored dot + one line (`Syncing…` / `Up to date` /
   `On this device only — iCloud not available` / `Sync error`), tappable to a small
   detail (the reason string, pending count, and a "Try again" that re-runs
   `startIfManuallyEnabled()`). If the gate is off, the row is the enable affordance.

**Tests:** `SyncHealthTests` in `GalavantSchemaTests` — the reducer, exhaustively.
The model + view are the thin integration layer (app target, untested).

**Done when:** turn iCloud off in the sim → Settings says "On this device only" with
the reason, not silence; capture an idea offline → the row shows pending>0 then clears
when it drains; on a healthy device it reads "Up to date." (Real verification is
two-device, on the TestFlight build — this slice is what makes that verification
*legible*.)

---

## M5-pinned — booked reservations as absolute, pinned stops · **Opus** for slice 1 (date-slide semantics are judgment), Sonnet-friendly after

**ADR / rationale:** `docs/trip-time-model.md §4` (read it) + the BACKLOG entry
"Booked reservations as absolute, pinned stops."

**Goal:** a confirmed reservation (OpenTable, hotel, timed museum entry) is an
**absolute fact** — nailed to a calendar date, and it must **not** slide when the
trip's start date moves. Today every `TripIdea` is **day-relative** (`dayNumber` +
the `Schedule` columns; dates are *derived* from `Trip.startDate`, never stored —
that's deliberate, trip-time-model §2). A booked stop is the deliberate exception:
it stores an absolute date and its day number is *re-derived* when the start slides.

**Why it's additive, not a re-open of `Schedule`:** M3c dropped V2's `.exact(Date…)`
case on purpose. We are **not** bringing it back into the facade. Instead, `pinnedDate`
is an orthogonal override *column* on `TripIdea` — the read-model consults it to place
the stop; the `Schedule` enum stays date-free. Same table, same single FK (→ `Trip`),
so nothing new to register with the SyncEngine.

**Precedent to clone:** the `TripStay` additive-schema slices (ADR-0011) and the
existing derivation direction `Trip.date(forDay:)` — you're building its inverse
(`date → dayNumber` given the trip start).

**Slices:**
1. **Schema + pure derivation.** Additive columns on `TripIdea`: `pinnedDate: Date?`
   plus booking metadata (`bookingConfirmation: String?`, `bookingURL: String?`,
   `partySize: Int?`, and a `isBooked`/kind signal — booked-vs-planned). Additive
   migration in `Database.swift`. Pure core: given a dated trip, a pinned stop's
   **effective day** is `Trip.dayNumber(for: pinnedDate)` (the inverse of
   `date(forDay:)`); when `startDate` slides, the pinned stop keeps its date and its
   day recomputes, while unpinned stops keep their `dayNumber` and slide. Fold this
   into the itinerary read-model (`TripPlan`) so ordering + the "Now" marker treat a
   pinned stop by its real date. **Exhaustive tests** for the slide behavior (pin two
   stops, move the start ±N days, assert pinned stays put and planned slides; a pin
   outside the trip's day range clamps like other out-of-range days).
2. **Itinerary + canvas honor it.** The pinned stop renders on its derived day with a
   **booked badge** (distinct from a soft daypart/hard clock time — it's a *fixed
   fact*, the strongest tier of the existing time vocabulary, itinerary-cleanup.md),
   and is **excluded from reorder/slide** affordances. Canvas pin unchanged (it's
   still a located stop).
3. **Write path.** A "Booking" section in the stop form (confirmation #, URL, party
   size, the date/time) that sets `pinnedDate`. Natural capture hook: an OpenTable /
   hotel-confirmation share creates a pinned stop directly — but that's the M4-capture
   seam; slice 3 here is the manual editor. Pairs with the "reservable-from"
   booking-window work (a future notification lives off `pinnedDate`).

**Tests:** `GalavantSchemaTests` — the date↔day derivation + slide semantics (slice 1
is the whole risk; get it bulletproof).

**Done when:** book a stop for a real date on a dated trip, slide the trip start by 2
days → the booked stop stays on its calendar date (its day number changes) while
planned stops move with the trip; the booked stop shows a fixed-fact badge and won't
reorder.

---

## M5-calendar — mirror the itinerary into an Apple Calendar (EventKit) · **Opus** (EventKit access model + the reconcile discipline are the risk)

**Goal:** a dedicated `Galavant Travel` calendar that shows the trip's itinerary in
each planner's Calendar.app and **stays current as the trip changes** — so "include it
in our overall iCal view" is just leaving that calendar checked. Once a trip is
**dated**, Galavant keeps a per-device calendar mirror of its scheduled stops. Undated
trips have nothing to place (day-relative only) — nothing to mirror.

### The load-bearing principle — *project, never share the calendar*

The couple's-trip case (the 95%) is handled **one layer down**, not at the calendar.
The trip is already CloudKit-shared over the travel party (root + trips + ideas), so
**both planners' Galavants already hold the same trip.** Each device therefore renders
its own local `Galavant Travel` calendar from its own copy of the shared trip. Both
calendars look identical because they project the same synced trip — *not* because any
calendar is shared.

```
              the shared trip  (CloudKit travel-party share)
             /                                              \
     Jon's Galavant  ──projects──▶  Jon's local calendar  ──▶  his Calendar.app
     Her Galavant    ──projects──▶  Her local calendar   ──▶  her Calendar.app
```

Consequences to honor in the build:
- **Never create a shared/CalDAV calendar, and never write to one.** EventKit can't
  provision calendar sharing anyway, and two Galavants writing one calendar is a
  two-writer conflict for zero benefit (both planners already see identical events via
  their own projections). One writer per calendar, always: **this device's Galavant is
  the sole writer of this device's mirror.**
- **The mirror is a one-way, read-only output.** Galavant is the source of truth; the
  calendar is a projection. An edit made *in Calendar.app* is transient — the next
  reconcile **stomps** it back to match the trip. State this in the code comment: the
  calendar is glanceable output, never an input.
- **"In sync" = reconciled on trip-change + foreground, not real-time.** No server
  (ADR-0001) → no daemon. Each planner's calendar is current as of *their own* last
  Galavant session: you edit → your mirror updates that session → the change rides
  CloudKit → their mirror updates next time *their* Galavant runs. That eventual
  consistency is acceptable for a planning app; don't pretend it's live.

### Precondition (verify, don't assume)

The couple's flow rides entirely on the **travel-party share-accept working on two real
devices** — the handshake deferred since M1 (ADR-0003, "accept handshake deferred to
real-device test at M5"). No accepted share ⇒ the other planner's Galavant has no trip
⇒ nothing to project. So this slice is **downstream of the two-device TestFlight
verification** and can't be fully proven until that lands. Build it single-device
first; the shared case is verified as part of the same two-device push as sync health.

**Slices:**
1. **Pure `TripCalendarMirror` core** in `GalavantSchema` — map the itinerary
   read-model (`TripPlan` / `[ItineraryDay]`) → a **desired** `[CalendarEvent]` set, a
   plain value type (`title`, `start: Date`, `end: Date?`, `isAllDay: Bool`,
   `location: String?`, `notes: String?`, and a **stable external key** — reuse
   `TripIdea.id` — the reconcile join key). Time mapping off the `Schedule` facade:
   `.timed` → exact start/end; `.daypart` → anchored at `DayPart.sortHour`; `.day` →
   all-day; a **pinned/booked** stop (M5-pinned) → its absolute `pinnedDate` time (the
   truest event of all). Dates come from `Trip.date(forDay:)`; dated trips only.
   **No EventKit import here.** Also pure: the **reconcile diff** — given the desired
   set and the set already on the calendar (as `[key: existingID]`), compute
   `create` / `update` / `delete` by external key. This diff *is* the whole "stays in
   sync" behavior; unit-test it exhaustively (add a stop → one create; retime → one
   update; remove → one delete; unchanged → no-op; re-run → idempotent).
2. **Injectable `CalendarClient`** (`@Dependency`, EventKit isolated behind it —
   `inject-io-boundaries-early`, same pattern as `PlaceSearchClient`/`directionsClient`).
   Applies the diff: ensure/find the single `Galavant Travel` calendar, create/update/
   delete `EKEvent`s by the stashed external key. **Skill checkpoint — a maintained
   mirror needs full access, not write-only:** the fire-and-forget `requestWriteOnlyAccessToEvents`
   is *not* enough here, because reconcile must **read back** existing events to
   update/delete them → use `requestFullAccessToEvents` (iOS 17+) and add
   `NSCalendarsFullAccessUsageDescription` in `project.yml`. Verify the current API
   against the SDK headers (`apple-sdk-headers-authoritative`) rather than recalling it.
   **Calendar source:** create the calendar in the **local** source for v1 (simplest,
   single-writer-per-device; each of a planner's own devices keeps its own copy). Note
   the iCloud-source upgrade — shows on all of that planner's devices automatically —
   as a **follow-on** that trades in a mini multi-writer problem (two of *your* devices
   writing one iCloud calendar), tolerable only because the keyed reconcile is
   idempotent. Don't do iCloud-source in v1.
3. **Drive the reconcile.** A per-trip **"Mirror to Calendar" toggle** (so you're not
   auto-populating half-baked trips — opt in per trip). While on, run the reconcile on
   trip `DatabaseChange` + scene `.active` (reuse the existing scene hooks), bounded and
   idempotent. Toggling off deletes the trip's events from the mirror.

**Tests:** `GalavantSchemaTests` — the pure `TripCalendarMirror` mapping *and* the
reconcile diff (create/update/delete/no-op/idempotent by key; all `Schedule` cases;
dated-only guard; pinned → absolute time). The diff is the risk; make it bulletproof.
`CalendarClient` is the I/O boundary (thin, exercised on device).

**Done when:** turn on "Mirror to Calendar" for a dated trip → a `Galavant Travel`
calendar appears in Calendar.app with a correctly-timed event per stop (all-day for
bare days, clock times for `.timed`, absolute time for booked stops); edit the
itinerary → the calendar updates without duplicating; remove a stop → its event
disappears; edit an event in Calendar.app → the next reconcile restores it. **Two-device
(the 95% case):** both planners, sharing the trip, each see the same itinerary in their
own Calendar.app — verified on the same two-device build as share-accept + sync health.
