# Handoff: Today — execution (complete, skip, defer, tap-to-detail)

Status: Dispatched
Summary: Make the Today iPhone cockpit usable *on the day*: check stops off,
watch NEXT advance and a progress count fill, fold completed/skipped stops away,
skip or defer the ones you're not doing now, and tap any stop to open its detail.
Fixes the inert "Anytime day" (a walking tour where the clock can't advance NEXT).

Implements: ADR-0039 (`docs/decisions/0039-today-execution-completion-skip-defer.md`).
Read it first — it carries the *why* and the decisions; this brief is the *how*.
Supersedes ADR-0038's read-only restraint for Today (Journey stays read-only).

Depends on: the day-preview slice (`docs/handoff/today-day-preview.md`). This brief
assumes `TodayView` already has the `isPreviewing` / `currentDay` / `renderNow`
machinery from that work. If that hasn't landed yet, land it first.

---

## Shared context (read first)

Repo: galavant (V3) at `~/code/galavant/galavant`. Household iOS app, SwiftUI,
SQLiteData+CloudKit, no server, Point-Free style **without TCA**. Read `AGENTS.md`
+ `CLAUDE.md` first. Conventions that bite:

- **Branch + PR workflow:** never push to `main`. Feature branch off `main`, open a
  PR. **No git worktrees** — a plain checkout on your branch is correct.
- **XcodeGen-managed project:** `project.yml` is the source of truth,
  `project.pbxproj` is generated AND tracked. Run `xcodegen generate` **only if you
  add/remove a file in the _app_ target**, and then commit BOTH. This brief adds
  **one** new app file (a small Today row view is optional — you may instead edit
  the existing `TodaySupportingViews.swift`, which needs no regenerate). Package
  files and package test files need no xcodegen. **Prefer editing existing files.**
- App builds with `-skipMacroValidation` (macro trust may need re-approval in
  Xcode). Build/run via Xcode/`xcodebuild`. `swift test` aborts here on unrelated
  FoundationModels targets — run `GalavantSchemaTests` the way the repo already does
  (exclude the FM-linked test targets per `AGENTS.md`, or use Xcode's test
  navigator against the `GalavantSchema` scheme). Don't claim green if you only
  built.
- **Today is iPhone-only** (entry gated on `!usesColumn`, `TripPlanningView.swift:87`).
  Review on an **iPhone** simulator. Leave that gate alone; no iPad path.
- **This is a synced schema change.** Adding columns to `TripIdea` touches
  SQLiteData + CloudKit. Additive nullable columns are safe; follow the existing
  migration idiom exactly (below). No CloudKit console changes are needed for
  additive columns.
- Match surrounding comment density/idiom. No version suffixes (ADR-0006). Keep the
  functional core pure and tested; feature-model writes are thin wrappers over the
  DB ops.

### Files

- `GalavantLibrary/Sources/GalavantSchema/TripIdea.swift` — add two columns + init
  params + a `StopOutcome` facade.
- `GalavantLibrary/Sources/GalavantSchema/Database.swift` — one migration.
- `GalavantLibrary/Sources/GalavantSchema/TodayProjection.swift` — pending-aware
  NEXT, progress, outcome-based collapse.
- `GalavantLibrary/Sources/GalavantSchema/TripOperations.swift` — complete/skip/
  defer DB ops (pure DB functions, statics).
- `Galavant/Trips/TripPlanningModel.swift` (or a small `+Today` extension) — thin
  async wrappers the view calls.
- `Galavant/Today/TodayView.swift` + `Galavant/Today/TodaySupportingViews.swift` —
  the affordances.
- Tests: `GalavantLibrary/Tests/GalavantSchemaTests/TodayProjectionTests.swift` and
  the trip-operations test suite.

---

## Phase 0 — Bug fix (do FIRST, independent of the rest): transfer-day rows dropped from REMAINING

**Symptom** (found dogfooding, 2026-08-16, on a transfer day — Day 3, Fri Aug 28,
Bavaria): the planning Itinerary tab correctly shows `Check out BEYOND BY GEISEL →
1 hr 8 min drive to Das Achental → Check in Das Achental → < 1 min walk → es:senz`,
but Today's **REMAINING** shows only `< 1 min walk to es:senz` and `es:senz`. The
**check-out, the between-lodgings drive, and the check-in are missing.** Reproduces
on more than one transfer day. It surfaced in *preview* (start-of-day) but is a
**live bug too** — at any time before check-out on the real day, those rows are
still ahead yet get dropped.

**Root cause** (pure core, pre-existing — not caused by the preview or execution
work):

- `TripPlan.nowMarkerIndex(in:day:now:tripStartDate:)`
  (`TripPlan.swift:539`) computes the now-marker's position **relative to `stops`
  only** — it never considers stay boundaries (`.checkIn`/`.checkOut`) or
  connectors.
- On a transfer day the assembled row stream is, in order:
  `[checkOut, transferConnector(drive), checkIn, nowMarker, walkConnector, es:senz]`
  — the marker lands *after* the morning boundary rows because it's positioned by
  stop index (before the first upcoming stop, es:senz), oblivious to the boundaries
  that sort ahead of it.
- `TodayProjection.remainingTimeline(items:nextIndex:)`
  (`TodayProjection.swift:168`) then computes
  `remainingStart = min(markerIndex, completedEnd)` and returns
  `items[remainingStart...]`. With `markerIndex == 3`, it slices off indices 0–2
  (check-out, transfer drive, check-in). Those rows are neither rendered as
  "remaining" nor counted into "Earlier today" — they simply vanish.

The core mistake: **the earlier/remaining divider is computed from the now-marker's
array position, but that position is only valid for stops.** Non-stop rows
(boundaries and their connectors) that sort before the marker but are still in the
future get incorrectly collapsed away.

**Fix requirement:** the earlier↔remaining split must be decided by whether each
row is actually **past**, across ALL row types (stops, `.checkIn`/`.checkOut`
boundaries, connectors, calendar constraints) — not by the now-marker's
stop-relative index. Concretely, a row belongs to REMAINING when its nominal time
is at-or-after `now` (using each row's own time: a boundary's
`checkOutSortMinutes`/`checkInSortMinutes`, a connector's owning event, a stop's
`nominalDate`). At start-of-day (preview) nothing is past, so the whole day —
check-out, drive, check-in, walk, dinner — must appear and "Earlier today" must be
empty. Keep the now-marker itself (its stop-relative placement is fine for the "you
are here" dot); only the *collapse divider* must stop keying off it.

**Regression test** (`TodayProjectionTests.swift`): build a transfer day — one stay
with `checkOutDay == D`, a second with `checkInDay == D`, a `betweenLodgings`
travel time so the transfer connector resolves, and one timed evening stop —
`resolve` at `date(day: D, hour: 0)` (start-of-day, the preview instant) and assert
`remaining` contains a `.checkOut`, the between-lodgings `.connector`, and a
`.checkIn`, with no `.earlierToday`. Add a second assertion at a mid-morning `now`
*before* the check-out time (live case) that those rows are still present.

**Sequencing:** land this first as a standalone correctness fix. Phase 3 rewrites
`remainingTimeline` for outcome-based collapse — it MUST preserve this behavior
(the Phase 3 collapse divider is decided by outcome for stops **and** by
past-ness for boundaries/connectors; never by the now-marker's index). If you build
Phase 3 directly, fold this fix into it and keep both regression tests.

---

## Phase 1 — Schema: the outcome overlay (pure + migration)

**Goal:** record completion/skip on the stop as two reversible, mutually exclusive
timestamps; expose a total in-memory `StopOutcome`.

### 1a. Columns on `TripIdea` (`TripIdea.swift`)

Add after `partySize` (keep the `@Table` property order stable; append):

```swift
/// Execution overlay (ADR-0039): when the traveler checked this stop off, on the
/// day. `nil` for a stop not yet done. Mutually exclusive with `skippedAt`. The
/// stop stays `.scheduled` — completion is a lens Today lays over the plan, not a
/// status change.
public var completedAt: Date?
/// Execution overlay (ADR-0039): when the traveler skipped this stop ("not doing
/// it"). Mutually exclusive with `completedAt`.
public var skippedAt: Date?
```

Add matching `init` params (default `nil`) and assignments, mirroring the existing
ones. Then a facade:

```swift
/// Total in-memory reading of the execution overlay (ADR-0039), mirroring how
/// `Schedule` faces flat columns. Writes keep the two dates mutually exclusive, so
/// `completedAt` wins if both are somehow set (repaired on the next write).
public enum StopOutcome: Equatable, Sendable {
  case pending
  case done(Date)
  case skipped
}

extension TripIdea {
  public var outcome: StopOutcome {
    if let completedAt { return .done(completedAt) }
    if skippedAt != nil { return .skipped }
    return .pending
  }
  public var isPending: Bool { completedAt == nil && skippedAt == nil }
}
```

### 1b. Migration (`Database.swift`)

Append a NEW migration at the end of the existing chain (never edit a prior one),
matching the `ALTER TABLE "tripIdeas" ADD COLUMN` idiom already there:

```swift
migrator.registerMigration("Add execution overlay to tripIdeas") { db in
  try #sql(#"ALTER TABLE "tripIdeas" ADD COLUMN "completedAt" TEXT"#).execute(db)
  try #sql(#"ALTER TABLE "tripIdeas" ADD COLUMN "skippedAt" TEXT"#).execute(db)
}
```

(Confirm the `Date`↔column affinity against the existing `pinnedDate` column — use
the SAME SQL type/affinity SQLiteData uses for `pinnedDate: Date?` so encoding
matches. If `pinnedDate` is stored as something other than `TEXT`, match that.)

**Acceptance:** package compiles; a stop round-trips `completedAt`/`skippedAt`
through the DB; `outcome` derives correctly.

---

## Phase 2 — DB ops (`TripOperations.swift`)

Add static DB functions next to the existing scheduling ops. Keep them pure DB
mutations (take `in db: Database`), mirroring `schedule(_:stopID:in:)`.

```swift
/// Mark a scheduled stop done at `now`, clearing any skip (ADR-0039). Idempotent.
public static func complete(stopID: TripIdea.ID, at now: Date, in db: Database) throws
/// Clear a stop's done state (un-check).
public static func uncomplete(stopID: TripIdea.ID, in db: Database) throws
/// Mark a stop skipped at `now`, clearing any completion (ADR-0039).
public static func skip(stopID: TripIdea.ID, at now: Date, in db: Database) throws
/// Clear a stop's skipped state (un-skip).
public static func unskip(stopID: TripIdea.ID, in db: Database) throws
```

Implement with the `TripIdea.find(id).update { … }` pattern used elsewhere in this
file; enforce mutual exclusion in each (e.g. `complete` sets `completedAt = now`,
`skippedAt = nil`).

**Defer** reuses existing ops — do NOT add new persistence:
- **To tomorrow:** `schedule(.day(currentDay + 1), stopID:, in:)`.
- **Later today:** set `dayRank` to just past the day's current max (follow the
  `dayRank` reorder pattern near `TripOperations.swift:478`). If a clean "move to
  end of day" helper doesn't already exist, add a small one alongside the reorder
  code rather than reimplementing ordering in the view.

**Tests** (trip-operations suite): complete→outcome `.done`; skip clears
completion and vice versa; uncomplete/unskip return to `.pending`; a stop stays
`status == .scheduled` throughout (still in the plan).

---

## Phase 3 — Projection: pending-aware NEXT, progress, outcome collapse

All in `TodayProjection.swift`. `ResolvedStop.entry` is the `TripIdea`, so
`stop.entry.isPending` / `.outcome` / `.completedAt` are already available — no new
plumbing.

1. **NEXT is the first pending upcoming stop.** In `next(in:…)`
   (`TodayProjection.swift:131`), require `stop.entry.isPending` in addition to
   `isUpcoming`. On an Anytime day this makes NEXT = first pending stop, so
   completing it advances to the next.
2. **Progress.** Add to the projection a small value the header renders, computed
   over the rendered day's scheduled stops:
   ```swift
   public struct Progress: Equatable, Sendable { public var done: Int; public var total: Int } // total = done + pending
   ```
   `done` = stops with `.done`; `total` = done + pending (skipped excluded). Put it
   on `TodayProjection` (e.g. `public var progress: Progress`).
3. **Collapse by outcome — on top of the Phase 0 past-ness divider.** After Phase 0,
   the earlier↔remaining split is decided by whether a row is actually past (across
   stops, boundaries, connectors), NOT by the now-marker index. Layer outcome on
   top for **stops only**: a `.done`/`.skipped` stop folds into the leading summary
   regardless of the clock; a `.pending` stop stays in REMAINING even if its time
   has passed (it's not done — it's outstanding, not "earlier"). Non-stop rows
   (check-in/check-out/connectors/constraints) collapse purely by past-ness, exactly
   as Phase 0 established. The existing `RemainingItem.earlierToday(count:)` can
   carry the "done/handled" count; to distinguish skipped, add a sibling case (e.g.
   `.skipped(count:)`) rather than overloading `earlierToday`. Keep the shape a value
   the view renders; no view logic in the core.

   **Preview (non-live day):** every stop is pending and nothing is past (start-of-
   day), so this correctly reduces to "the whole day in REMAINING, nothing
   collapsed" — i.e. the **Phase 0-fixed** behavior, NOT the old buggy slice. Do not
   special-case "preview"; drive collapse off outcome (all `nil` in preview) + Phase
   0 past-ness (nothing past at start-of-day).

**Tests** (`TodayProjectionTests.swift`, reuse its fixtures): build an all-Anytime
day; assert NEXT = first stop; mark the first `.done` (set `completedAt` on the
entry in the fixture) and assert NEXT advances to the second and `progress ==
(1, N)`; mark one `.skipped` and assert it leaves the denominator and folds into the
collapse; a `.pending` stop whose time has passed stays in REMAINING (not collapsed);
and a fully-pending transfer day at start-of-day keeps check-out + transfer + check-in
(the Phase 0 regression test, which Phase 3 must not regress).

---

## Phase 4 — Model wrappers (`TripPlanningModel`)

Add thin `@MainActor` async methods the view calls; they run the Phase-2 DB ops via
the model's existing DB seam, then let `@FetchAll` refresh the plan (no manual state
poke). Names: `completeStop(_:)`, `uncompleteStop(_:)`, `skipStop(_:)`,
`unskipStop(_:)`, `deferStopToTomorrow(_:)`, `deferStopToLaterToday(_:)`. Use the
`@Dependency(\.date)` clock for the timestamp (don't call `Date()` directly).

---

## Phase 5 — The view (`TodayView.swift` + `TodaySupportingViews.swift`)

**Gate all write affordances to the live day:** `let canExecute = !isPreviewing`.
In preview, rows are tappable (detail) but show no check / menu, and no progress
count. (Reason: outcomes belong to the actual day; pre-checking a future day is
meaningless.)

1. **Progress in the header.** In `TodayDayHeader`, when `canExecute` and
   `progress.total > 0`, show "`\(done) of \(total)`" (e.g. next to "Day N").
   Keep it quiet — a subheadline/secondary count, not a big meter.
2. **NEXT card check-off.** In `TodayNextHero`, when `canExecute`, add a primary
   "Done" affordance (e.g. a check button beside/under Directions) calling
   `completeStop(next.item)`. Completing advances NEXT reactively.
3. **Row affordances.** In `TodayTimelineRow` (stops only), when `canExecute`:
   - Leading: a tappable check circle → `completeStop` / `uncompleteStop` (toggles
     on `.done`). Reuse the row's existing leading dot slot; a filled check for
     `.done`.
   - Trailing: a `Menu` ("…") with **Skip** (`skipStop`), **Do later today**
     (`deferStopToLaterToday`), **Do tomorrow** (`deferStopToTomorrow`, hide on the
     last trip day). Keep the two tap targets distinct (`contentShape` on each) so
     the check and the menu don't steal the row's detail tap.
   - Give the check and menu buttons `.buttonStyle(.plain)` and their own hit
     shapes so the row body tap (detail) still works.
4. **Collapse rendering.** In `TodayTimeline`, render the outcome summary the core
   now produces ("Done · N", "Skipped · M") in place of / alongside the existing
   "Earlier today · N" label. Pending stops render as today.
5. **Directions on every travel leg (ADR-0039 addendum, live AND preview).** The
   connector rows currently render an ETA ("1 hr 7 min drive") as inert text, so on a
   transfer day the drive you're about to take has no way to launch. Add a Directions
   affordance to the connector row (`TodayTimelineRow`'s connector case / the
   equivalent row in `TodaySupportingViews.swift`) calling the **existing**
   `openInMaps(connector:)` (`TripItineraryView.swift:419`) — the same function the
   NEXT hero already uses. No new core code; the connector already carries
   `from`/`to`/`mode`. Emphasize the *current* leg (the one at/after the now-marker)
   as the prominent action and keep later legs' quiet; **suppress** the affordance on a
   trivial leg (a "< 1 min walk") so it isn't noise. This is why NEXT stays
   stop-shaped: the transfer's value is its Directions, which now lives on the leg — do
   NOT make NEXT select non-stop rows.
6. **Tap-to-detail (live AND preview).** Add `@State private var detailIdea: Idea?`
   to `TodayView`; a tap on the NEXT card and on each stop row sets it; present:
   ```swift
   .sheet(item: $detailIdea) { idea in /* reuse the existing idea-detail view */ }
   ```
   Reuse whatever `TripPlanningModel.showDetail(_:)` presents (see
   `TripPlanningModel.swift:429`) — present that same detail view here as a local
   sheet rather than routing through the planning model (its presentation lives
   behind this fullScreenCover). Rows/cards without an `idea` (freeform stops) are
   simply non-tappable for detail.

Do NOT change `TodayModel`, the weather path, the day-stepper, or the preview
gating from the day-preview slice.

---

## Behaviour matrix (acceptance)

| Situation | NEXT | Progress | Row affordances | Detail tap |
| --- | --- | --- | --- | --- |
| Live Anytime day | First pending stop; advances on check-off | "2 of 6" | check + …(Skip/Later/Tomorrow) | yes |
| Live: all done | "Nothing else is scheduled" | "6 of 6" | uncheck to reopen | yes |
| Preview (other day) | First stop (plan order) | hidden | none (read-only) | yes |
| Skipped a stop | denominator drops by 1; folds into "Skipped · M" | e.g. "2 of 5" | unskip via menu | yes |

Round-trip: on the live day, check off the first three Munich stops → they fold
into "Done · 3", NEXT is the fourth, header reads "3 of N", and (if a second device
shares the trip) the check-offs sync. Undo returns them.

---

## Watch-outs

- **Mutual exclusion:** every write path must clear the other timestamp. Enforce it
  in the DB ops (Phase 2), not the view.
- **Plan stays intact:** never flip `status` to `.done`/`.skipped` for the live
  check-off — that would strip the stop from the `.scheduled` plan
  (`TripPlan.swift:242`). Overlay only. (The status terminals stay reserved for the
  future post-trip pool roll-up — out of scope here.)
- **Reactivity:** rely on `@FetchAll` refreshing `planningModel.plan` after a
  write; don't cache outcome in the view.
- **Date encoding:** match `pinnedDate`'s column affinity so `completedAt`/
  `skippedAt` round-trip identically.
- **Tap-target collisions** in the row: check circle vs "…" menu vs body-tap for
  detail each need their own `contentShape`/button; test all three on device.
- **Freeform stops** (`ideaID == nil`) have no idea detail — leave them
  non-tappable for detail but still checkable.
- Keep the day-stepper and preview read-only guarantee intact; execution is
  live-only.
