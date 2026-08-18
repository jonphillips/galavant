# Codex task: official vs. planned check-in/check-out times for lodging stays

## Goal

A lodging stay (`TripStay`, ADR-0011) currently has one optional time per boundary
(`checkInTime` / `checkOutTime`) that doubles as both the displayed time and the
itinerary sort key. Split each boundary into two times:

- **Official time** — the property's stated check-in / check-out time. This is the
  *existing* `checkInTime` / `checkOutTime` column (its current 15:00 / 10:00 seeds
  already read as the official convention). Do **not** rename these columns.
- **Planned time** (new) — "when we think we'll actually check in / out." Optional,
  independent per boundary.

Render both, sketch (applies to the Trip itinerary row **and** the Today timeline row):

```
🔑  Check in (15:00)              9:30
    Hampton Inn
```

- Label line: `Check in` / `Check out`, with the **official** time in parentheses —
  **but only when a planned time is also set** (so it contrasts against the trailing
  number). When only one time exists, no parenthetical.
- Trailing prominent time = `planned ?? official`. When neither is set, no trailing
  time (unchanged from today).

The stay sorts on the timeline where we'll *actually* be: the sort key uses
`planned ?? official ?? default`.

The example reads most naturally as **check-out** (leave at 9:30 before an 11:00
deadline), but the model is symmetric — implement both boundaries identically.

## Repo conventions (must follow)

- Read `AGENTS.md` + `CLAUDE.md` first. Point-Free style, no TCA, value types,
  make-impossible-states-unrepresentable, dependencies not singletons.
- **No version suffixes in any identifier** (ADR-0006).
- **XcodeGen**: `project.yml` is source of truth. If you touch targets/products,
  `xcodegen generate` and commit both `project.yml` and `project.pbxproj`. This task
  likely needs no project.yml change (no new files/targets required).
- **Branch + PR workflow**: never push to `main`. Work on a feature branch
  (e.g. `feat/stay-planned-times`) and land via PR.
- **Verification is compile + unit tests only.** Do not run the simulator, do not
  install/launch on a device — Jon reviews on his own device. Note: `swift test`
  aborts in this repo when FoundationModels-linked test targets are present; run the
  schema tests the way the repo already documents (temporarily disabling FM test
  targets if needed) — see the "swift test FoundationModels host gap" note. The app
  builds with `-skipMacroValidation`.
- Keep pure/value logic in the `GalavantSchema` functional core so it's testable
  without a database or an `@Observable` (the "watch for fat models" rule).

## Changes

### 1. Schema — `GalavantLibrary/Sources/GalavantSchema/TripStay.swift`

- Add two stored properties:
  ```swift
  public var plannedCheckInTime: String?
  public var plannedCheckOutTime: String?
  ```
  Add them to the memberwise `init` (default `nil`, placed after the existing time
  params) and to the `freeform(...)` factory. Update the doc comment: `checkInTime`
  / `checkOutTime` are now explicitly the **official** property times; the two new
  fields are the personal planned times.
- Update the sort ladders to prefer the planned time:
  ```swift
  public var checkInSortMinutes: Int {
    plannedCheckInTime.flatMap(Schedule.minutes(from:))
      ?? checkInTime.flatMap(Schedule.minutes(from:))
      ?? Self.defaultCheckInMinutes
  }
  ```
  and the symmetric `checkOutSortMinutes` (`plannedCheckOutTime ?? checkOutTime ??
  default`).
- Add a **pure presentation helper** for the two-time display so both views share
  one tested source of truth:
  ```swift
  extension TripStay {
    /// The two times a check row shows. `trailing` is the prominent right-aligned
    /// time (planned when set, else official). `officialParenthetical` is the
    /// property time shown after the label — present ONLY when a planned time also
    /// exists, so it reads as a contrast, never a duplicate of `trailing`.
    public struct CheckDisplay: Equatable, Sendable {
      public var trailing: String?
      public var officialParenthetical: String?
    }
    public var checkInDisplay: CheckDisplay { ... }   // uses planned/official check-in
    public var checkOutDisplay: CheckDisplay { ... }  // uses planned/official check-out
  }
  ```
  Logic per boundary: `trailing = planned ?? official`; `officialParenthetical =
  (planned != nil && official != nil) ? official : nil`.

### 2. Migration — `GalavantLibrary/Sources/GalavantSchema/Database.swift`

Register a **new** migration (do not edit the existing "Create tripStays table"
migration) that adds the two nullable columns:

```swift
migrator.registerMigration("Add planned check times to tripStays") { db in
  try #sql(#"ALTER TABLE "tripStays" ADD COLUMN "plannedCheckInTime" TEXT"#).execute(db)
  try #sql(#"ALTER TABLE "tripStays" ADD COLUMN "plannedCheckOutTime" TEXT"#).execute(db)
}
```

Both nullable/additive so it's CloudKit-sync-safe with the SQLiteData SyncEngine.
Confirm the migration is registered before `migrator.migrate(database)` and after the
existing tripStays migration.

### 3. Write ops — `GalavantLibrary/Sources/GalavantSchema/TripStayOperations.swift`

Thread the two new optional params through `create`, `createFreeform`, and `edit`
(default `nil`), and bind them in the insert/update, mirroring the existing
`checkInTime` / `checkOutTime` handling.

### 4. Draft + editor — `Galavant/Trips/TripPlanningModel.swift` &
`Galavant/Trips/TripPlanningSheets.swift`

- `StayDraft`: add `var plannedCheckInTime: String?` and `var plannedCheckOutTime:
  String?`.
- `StaySheet`: in each of the **Check-in** and **Check-out** sections, keep the
  existing time row (relabel it **"Official"**) and add a second `timeRow` labeled
  **"Planned"** bound to the planned field. Reuse the existing `timeRow` toggle idiom.
  Seed the planned toggle from the official time when one is set, else the section's
  current default seed (15:00 / 10:00). No new validation — times remain optional and
  independent.

### 5. Save/seed path — `Galavant/Trips/TripPlanningModel+Scheduling.swift`

- Where a `StayDraft` is built from an existing `ResolvedStay` for editing, seed the
  two new draft fields from the stay.
- In `saveStay`, pass `plannedCheckInTime` / `plannedCheckOutTime` through to the
  `create` / `createFreeform` / `edit` ops.

### 6. Render surfaces

- **Trip itinerary** — `Galavant/Trips/TripItineraryView.swift`, `checkRow(_:isCheckIn:)`
  (~line 293). Replace the single-`time` logic with the shared helper: pick
  `stay.stay.checkInDisplay` / `checkOutDisplay`. Put `officialParenthetical` after the
  "Check in"/"Check out" label (e.g. `Check in (15:00)`, secondary/smaller), and render
  `trailing` in the existing right-aligned monospaced slot.
- **Today** — `Galavant/Today/TodaySupportingViews.swift`, the `.checkIn` / `.checkOut`
  cases (~line 272). `TodayTimelineEvent` currently gets `title:` + `detail:` (the hotel
  name). Extend it minimally so the check-in/out rows can show the same
  official-parenthetical-on-label + trailing-planned-time treatment, reusing the same
  `CheckDisplay` helper. Keep the change scoped to these two cases; don't disturb the
  `.homeBase` / `.calendarConstraint` / `.stop` rows beyond what's needed.

### 7. Tests — `GalavantLibrary/Tests/GalavantSchemaTests/TripStayTests.swift`

Add pure tests (no DB):

- `checkInSortMinutes` / `checkOutSortMinutes` ladder: planned wins over official;
  official used when planned nil; default when both nil.
- `checkInDisplay` / `checkOutDisplay` across all four combinations
  (neither / official-only / planned-only / both), asserting the parenthetical appears
  only when both are set and `trailing == planned ?? official`.

If a projection test (e.g. `TripPlanTests` / `TodayProjectionTests`) asserts on a
stay's timeline ordering, add/adjust one case proving a planned time moves the boundary
row's sort position.

### 8. Docs

- Amend `docs/decisions/0011-accommodations-as-stays.md`: note the official-vs-planned
  time split (this partially realizes the §4 "booked-vs-planned" seam for times only;
  pinnedDate / confirmation # / booking URL remain future).
- Add a one-line entry to `docs/DONE_LOG.md` and, if it's tracked as open anywhere,
  update `docs/CURRENT_HANDOFF.md`.

## Acceptance

- App target builds (`-skipMacroValidation`); `GalavantSchema` unit tests pass.
- A stay with only an official time renders and sorts exactly as before (no regression).
- Setting a planned time: it shows as the prominent trailing time, the official time
  moves into parentheses on the label, and the timeline row re-sorts to the planned
  time.
- New nullable columns migrate cleanly and round-trip through create/edit.
- Landed on a feature branch via PR (not pushed to `main`).
