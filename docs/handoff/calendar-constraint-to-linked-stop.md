# Handoff: Promote a Calendar constraint into a linked stop

Status: **Shipped** — 2026-08-18. Branch: `feat/promote-calendar-constraint-v1`; [PR #71](https://github.com/jonphillips/galavant/pull/71).
Design agreed 2026-08-18. V1 decisions locked (below).
Summary: A Calendar event that lands in the itinerary as a `CalendarTripConstraint`
(no place match) can currently only be **ignored** or left alone. This adds the
constructive third disposition: **give it a location and it becomes a real,
`.linked` itinerary stop** — the reverse of the normal match→link flow. No manual
idea creation, no "reconcile again and hope they link."

Implements: an amendment to **ADR-0034** (`docs/decisions/0034-calendar-reconciliation-authority.md`)
§6 (provenance) and §9 (`.linked` authority). Read that ADR first — it carries the
*why*; this brief is the *how*. The amendment itself is Prompt 6 below.

**V1 decisions (locked — do not widen):**
- **Placement is place-identity only.** Both input modes yield a real Apple Maps
  `mapItemIdentifier`. The raw-pin / coordinate-only fallback is **out of V1.**
- **Default input is tap-a-map-item.** Named-place search is the secondary mode.
- The promoted stop is therefore always **idea-backed**, never freeform.

---

## Shared context (every prompt assumes this — read once)

Repo: galavant (V3) at `~/code/galavant/galavant`. Household iOS app, SwiftUI,
SQLiteData + CloudKit, no server, Point-Free style **without TCA**. Read `AGENTS.md`
+ `CLAUDE.md` first. Conventions that bite:

- **Branch + PR workflow:** never push to `main`. One feature branch off `main`
  (suggested `feat/promote-calendar-constraint`), one PR. **No git worktrees** — a
  plain checkout on your branch is correct. Do all phases on the one branch.
- **Depends on the freeform-stop-location work.** `FreeformStopLocationSearchView`
  (`Galavant/Trips/FreeformStopLocationEditor.swift`) is used by Prompt 1's search
  mode. It currently lives on branch `codex/freeform-stop-location`. **Branch off
  `main` only after that has landed**, or branch off it. If the search view isn't
  present, stop and say so rather than reinventing it.
- **XcodeGen-managed project:** `project.yml` is the source of truth,
  `project.pbxproj` is generated AND tracked. Run `xcodegen generate` **only if you
  add or remove a file in the _app_ target**, then commit BOTH. This work adds
  new **app** files (Prompts 0, 1) — regenerate and commit the pbxproj with them.
  Package (`GalavantLibrary/...`) and package-test files need no xcodegen.
- App builds with `-skipMacroValidation` (macro trust may need re-approval in
  Xcode). Build/run via Xcode/`xcodebuild`. `swift test` aborts here on unrelated
  FoundationModels targets — run `GalavantSchemaTests` the way `AGENTS.md`
  prescribes (exclude the FM-linked test targets, or use Xcode's test navigator
  against the `GalavantSchema` scheme). **Don't claim green if you only built.**
- Match surrounding comment density/idiom. No version suffixes in identifiers
  (ADR-0006). Keep the functional core pure and tested; feature-model writes are
  thin wrappers over the schema DB ops.
- **Verification is compile + tests + hand off.** Do **not** install/launch a
  simulator or take screenshots — Jon reviews on his own device.

### The spine (what's reused vs new)

The event already owns the **time**; V1 only supplies the **place**. So the promote
action is: *create a placed, scheduled stop on the constraint's day → call the
existing link path.* Almost everything else already exists:

- Time / `.linked` authority / `pinnedDate` cache / ledger: written by the existing
  `CalendarReconciliation.manualLinkPlan` → model `persist` →
  `TripIdea.applyCalendarCommitment`. **Reuse, do not reimplement.**
- **Constraint reaping is automatic.** Once a `CalendarLinkedStop` exists for the
  event, `CalendarReconciliation.constraintPlan`
  (`GalavantLibrary/Sources/GalavantSchema/CalendarConstraintReconciliation.swift`)
  already deletes the constraint row in the same write. You should **not** hand-delete it.
- Tap-a-map-item → `Place` (with `mapItemIdentifier`): exists inside `PoolMapView`
  via `MapPlaceResolver.place(for:)`. Prompt 0 extracts it for reuse.

### Key files

- `Galavant/Ideas/PoolMapView.swift` — source of the POI-tap map (Prompt 0).
- `Galavant/MapPlaceResolver.swift` — `MapFeature` → `Place`.
- `Galavant/Trips/FreeformStopLocationEditor.swift` — `FreeformStopLocationSearchView` (search mode).
- `Galavant/Trips/TripItineraryView.swift` — `CalendarConstraintDetailSheet` (entry point, ~L479).
- `Galavant/Calendar/CalendarExportModel.swift` — the reconciliation model: existing
  `link(_:to:trip:plan:selectedCalendarID:)` (~L481), `persist` (~L363), candidate state.
- `GalavantLibrary/Sources/GalavantSchema/CalendarReconciliation.swift` — `manualLinkPlan`, `manuallyLinkedCandidate`.
- `GalavantLibrary/Sources/GalavantSchema/CalendarTripConstraint.swift` — the constraint (carries `dayNumber`, `sourceIdentityHash`, `title`, `location`).
- `GalavantLibrary/Sources/GalavantSchema/TripOperations.swift` — `pull`, `schedule` (place an idea as a scheduled stop on a day).
- `GalavantLibrary/Sources/GalavantPlaces/MapPlaceCapture.swift` — `Place` → `Idea.Draft`.

---

## Prompt 0 — Extract a reusable POI-selection map

> Read the Shared Context in `docs/handoff/calendar-constraint-to-linked-stop.md`
> first. **Refactor only — behavior-preserving.**
>
> Today the "tap a real Apple Maps place → resolve to a `Place` with a
> `mapItemIdentifier`" behavior lives only inside `PoolMapView`
> (`Galavant/Ideas/PoolMapView.swift`): a `Map(selection:)` with
> `.mapFeatureSelectionDisabled { $0.kind != .pointOfInterest }`, resolving the
> selected `MapFeature` through `MapPlaceResolver.place(for:)`
> (`Galavant/MapPlaceResolver.swift`).
>
> Extract a small reusable SwiftUI view — `PlaceSelectionMap` — that:
> - shows a `Map` whose **only** tappable targets are point-of-interest features
>   (reuse the exact `.mapFeatureSelectionDisabled` predicate and
>   `.mapFeatureSelectionAccessory(nil)` from `PoolMapView`);
> - resolves a tapped POI to a `Place` via `MapPlaceResolver` and calls
>   `onSelectPlace: (Place) -> Void`;
> - accepts an optional initial `MKCoordinateRegion` to frame, and optionally
>   renders a single existing pin annotation (for showing the current choice).
> - Do **not** render the pool markers or the search overlay — those stay in
>   `PoolMapView`.
>
> Repoint `PoolMapView` at `PlaceSelectionMap` so its POI-tap path is unchanged.
> Keep `PoolMapView`'s own markers, tint logic, framing, and `MapPlaceSearchOverlay`
> where they are. Its existing tests/snapshots must still pass.
>
> This adds one app file — run `xcodegen generate` and commit `project.yml` +
> `project.pbxproj` together. Build the app target. Report what you changed and
> confirm `PoolMapView` behavior is untouched.

## Prompt 1 — The location-picker sheet (two place-identity modes)

> Read the Shared Context and confirm Prompt 0 landed (`PlaceSelectionMap` exists).
>
> Add `AssignConstraintLocationSheet` (new app file under `Galavant/Calendar/` or
> `Galavant/Trips/` — match where the constraint UI lives). It takes a
> `CalendarTripConstraint` and hands back a chosen `Place`. Two modes, **default to
> map-item tap**:
> 1. **Tap a map item (default tab):** embed `PlaceSelectionMap` (Prompt 0). Frame
>    it on the constraint's day region if available; otherwise `.automatic`. A POI
>    tap selects that `Place`.
> 2. **Search:** reuse `FreeformStopLocationSearchView`
>    (`Galavant/Trips/FreeformStopLocationEditor.swift`), which already yields a
>    `Place` from `PlaceSearchModel`. Pre-seed its query with
>    `constraint.location ?? constraint.title`.
>
> **No raw-pin / coordinate-only mode — V1 is place-identity only.** Do not embed
> `FreeformStopLocationMap`.
>
> The sheet's output is a single resolved `Place` (guaranteed to carry a
> `mapItemIdentifier` from either mode). Present a confirm affordance ("Use this
> place") showing the picked name before committing. Wire the callback to the model
> method from Prompt 2; the sheet itself owns no DB writes.
>
> New app file → `xcodegen generate`, commit both. Build. This prompt is UI + wiring
> only; the create-and-link logic is Prompt 2.

## Prompt 2 — Create-and-link glue in the reconciliation model

> Read the Shared Context. This is the only genuinely new logic. Work in the
> reconciliation model (`Galavant/Calendar/CalendarExportModel.swift`).
>
> Add `promote(constraint: CalendarTripConstraint, place: Place, trip: Trip, plan: TripPlan) async`:
> 1. **Mint an idea-backed scheduled stop on `constraint.dayNumber`.** Turn the
>    `Place` into an `Idea` using `MapPlaceCapture.draft(for:)`
>    (`GalavantLibrary/Sources/GalavantPlaces/MapPlaceCapture.swift`) and insert it
>    (dedupe on `mapItemIdentifier` is already handled inside `draft(for:)`). Then
>    make it a **scheduled stop on the constraint's day** by following the existing
>    pull-then-schedule idiom in `GalavantLibrary/Sources/GalavantSchema/TripOperations.swift`
>    (`pull`, then `schedule(_:stopID:)` with a day-level `Schedule` for
>    `constraint.dayNumber`). Read a current call site (e.g. how Ideas/Recommendation
>    flows pull+schedule) and match it — do not invent new ops. **Do not set the
>    time here**; it arrives from the link in step 3.
> 2. **Resolve** the new `TripIdea` to a `ResolvedStop` by re-reading the plan.
> 3. **Find the event's candidate** and link. The model already holds the ingested
>    reconciliation candidates that back the sheet; locate the one whose event maps
>    to this constraint — match
>    `CalendarReconciliationFingerprint.constraintSource(for: candidate.input.event)`
>    against `constraint.sourceIdentityHash`. If candidates aren't loaded, run the
>    same ingest the sheet uses first. Then call the **existing**
>    `link(candidate, to: newStop, trip:, plan:, selectedCalendarID:)`. That routes
>    through `CalendarReconciliation.manualLinkPlan` → `persist`, which writes the
>    `.linked` schedule via `TripIdea.applyCalendarCommitment`, appends the
>    `CalendarLinkedStop`, records the ledger entry, and — because the event is now a
>    linked stop — lets `constraintPlan` delete the constraint row automatically.
>    **Do not hand-delete the constraint.**
>
> Guard: the event must be `isEligibleForSharedReconciliation && hasStableLocalIdentity`
> (constraints are only created for eligible events, so this should always hold — but
> assert/early-return rather than crash). Surface failures through the model's
> existing `state = .failure(...)` channel.
>
> Package logic that can be pure (matching a constraint to its candidate) should live
> in / be tested from `GalavantSchema` where practical. Build. Tests come in Prompt 5.

## Prompt 3 — Entry point on the constraint

> Read the Shared Context. Wire the UI to Prompt 2.
>
> `CalendarConstraintDetailSheet` (`Galavant/Trips/TripItineraryView.swift`, ~L479)
> is currently read-only (Title / Time / Location / Notes / Done). Add a primary
> action **"Give this a place"** that presents `AssignConstraintLocationSheet`
> (Prompt 1); on a chosen `Place`, call the model's `promote(...)` (Prompt 2), then
> dismiss. Optionally also add it as a leading swipe action on the constraint row in
> the same file (`calendarConstraintRow`, ~L248).
>
> After promote succeeds the constraint row should disappear (it's reaped) and the
> new linked stop appear on the day — verify the itinerary reflects both without a
> manual refresh (the fetches driving `TripItineraryView` should update from the
> write). The constraint's disposition set is now **Ignore / Give it a place / Leave**.
>
> No new files expected (editing existing app files) → no xcodegen. Build.

## Prompt 4 — Provenance flip: verify the deletion semantics

> Read the Shared Context and ADR-0034 §6.
>
> A promoted stop is a **Galavant-originated plan + linked commitment**, not a
> Calendar-originated constraint. So when the underlying Calendar event is later
> deleted, the app must ask the semantic **"keep as an unbooked plan or remove?"**
> question — **not** silently delete the stop (which is correct only for a
> Calendar-originated constraint).
>
> Trace the existing linked-stop deletion path (what happens in reconciliation when a
> `CalendarLinkedStop`'s event is confirmed deleted). Confirm a promoted stop takes
> the keep/remove branch, because it owns a real `TripIdea` the user placed.
> - If it already does: add a test asserting it (Prompt 5) and note it in the PR.
> - If it does **not** (e.g. it treats the promoted stop like a constraint and hard-
>   deletes): stop and write up the gap in the PR description with the exact call
>   path — do not invent a fix without flagging it first.

## Prompt 5 — Tests (GalavantSchema pure core)

> Read the Shared Context. Add tests to `GalavantLibrary/Tests/GalavantSchemaTests/`
> (see `CalendarReconciliationTests.swift` and `CalendarConstraintReconciliation*`
> for idiom). Run them the way `AGENTS.md` prescribes (FM targets excluded). Assert:
> - **Promote links, once.** Given a constraint + a chosen place, the manual-link
>   plan produces exactly one `CalendarLinkedStop` and one `linked` ledger entry, and
>   `constraintPlan` deletes the constraint (no duplicate stop, no orphaned constraint).
> - **Strong rung.** The place path links on `.mapItemIdentifier`.
> - **All-day constraint** → a day-level stop (nil `startTime`), not a timed one.
> - **Idempotency.** Re-running reconcile after promote is a no-op (no second stop,
>   no re-created constraint).
> - **Provenance (from Prompt 4).** After promote, event deletion yields the
>   keep/remove decision, not a silent stop deletion.
> Report pass/fail honestly with the command used.

## Prompt 6 — ADR amendment + docs

> Read the Shared Context. Amend, don't rewrite.
>
> - `docs/decisions/0034-calendar-reconciliation-authority.md`: add a short amendment
>   note (dated, like the others) recording the **reverse handoff** — a
>   Calendar-originated constraint may be promoted by assigning a place, which flips
>   it into a Galavant-originated plan + linked commitment (§6) under `.linked` time
>   authority (§9). One or two paragraphs; reference this handoff doc.
> - Update `docs/CURRENT_HANDOFF.md` status pointer and `docs/DONE_LOG.md` per repo
>   convention once the PR is green.
> - Flip this file's Status line to Shipped with the branch/PR.

---

## Open follow-ons (explicitly out of V1)

- Raw-pin / coordinate-only placement for places Apple Maps doesn't know.
- Bulk promote / promote-from-the-reconciliation-sheet (V1 entry is the constraint's
  own detail row).
