# Handoff: Trip View / Edit UX declutter

Separate **trip administration** from **trip use**. The trip view focuses on
planning/executing the itinerary; trip-level configuration moves behind Edit Trip
(reached from the Trips collection). Phones mid-trip are the priority surface.

Five phases. One PR is fine; if bundling, sequence **1 → 2 → 3a → 4 → 3b** so the
Phase 4 toolbar cut never strands a feature before Phase 3b gives it a home.

---

## Shared context (read first)

Repo: galavant (V3) at `~/code/galavant/galavant`. Household iOS app, SwiftUI,
SQLiteData+CloudKit, no server, Point-Free style without TCA. Read `AGENTS.md` +
`CLAUDE.md` first. Conventions that will bite you:

- **Branch + PR workflow:** never push to main. Work on a feature branch, open a PR.
- **Work in your OWN git worktree** (do not share the main checkout). Building from a
  worktree fails to resolve local SPM packages until you add this symlink:
  ```
  ln -s /Users/jon/code/jon-platform <worktree>/galavant/.claude/jon-platform
  ```
- **XcodeGen-managed project:** `project.yml` is source of truth, `project.pbxproj` is
  generated AND tracked. If you **add a new `.swift` file**, run `xcodegen generate` and
  commit BOTH `project.yml` (if changed) and the regenerated `project.pbxproj`. Editing
  existing files needs no regenerate. Prefer editing existing files.
- App builds with `-skipMacroValidation` (macro trust may need re-approval in Xcode).
  `swift test` aborts here (FoundationModels host gap) — don't rely on it; none of these
  phases touch FoundationModels.
- Layout gate everywhere: `usesColumn = horizontalSizeClass == .regular` (iPad).
- Match surrounding comment density/idiom. Keep pure/derivable logic testable; no version
  suffixes in identifiers (ADR-0006).

---

## Phase 1 — Dated day pills

**Goal:** on DATED trips the day chips read `M 8/24` (narrow weekday + M/D); undated trips
keep `Day N`. `All` chip and per-day colour/selection semantics unchanged.

**Context:**
- `Trip.date(forDay:)` (`GalavantLibrary/Sources/GalavantSchema/TripOperations.swift:136`)
  is pure/tested and returns `nil` for undated trips.
- The date-aware label helper `dayLabel(_:trip:)` lives in
  `Galavant/Trips/PlanningRow.swift:91` and yields the LONG form (`Day N · Wed, Aug 24`).
  It's used by section headers/pickers — do NOT change it.
- `DayChipBar` hardcodes `label: "Day \(day)"` at `Galavant/Trips/DayChipBar.swift:22` and
  already holds `model` (so `model.trip` is available).

**Changes:**
1. In `Galavant/Trips/PlanningRow.swift`, add a compact sibling next to `dayLabel`:
   ```swift
   /// Compact day label for the chip strip: "M 8/24" on a dated trip, "Day N"
   /// when undated. Weekday is narrow (single letter) by design — the M/D
   /// disambiguates the repeated S's and T's.
   func dayChipLabel(_ number: Int, trip: Trip?) -> String {
     guard let date = trip?.date(forDay: number) else { return "Day \(number)" }
     let weekday = date.formatted(.dateTime.weekday(.narrow))
     let monthDay = date.formatted(.dateTime.month(.defaultDigits).day())
     return "\(weekday) \(monthDay)"
   }
   ```
2. In `Galavant/Trips/DayChipBar.swift:22`, replace `label: "Day \(day)"` with
   `label: dayChipLabel(day, trip: model.trip)`.

**Acceptance:**
- Dated trip: chips render `M 8/24`, `T 8/25`, … `All` still first, still uncoloured.
- Undated trip: chips render `Day 1`, `Day 2`, …
- Selection tint/border and the per-day colour dot are unchanged.

**Watch-outs:** dated chips get a touch wider; the bar already scrolls horizontally, so no
layout change needed.

---

## Phase 2 — Trip-card Edit affordance

**Goal:** launch Edit Trip from the Trips collection with a VISIBLE affordance, not only a
hidden long-press.

**Context:**
- `Galavant/Trips/TripsScreen.swift`: `@State private var model = TripsListModel()`,
  `@Environment(AppRouter.self) router`. `tripCard(_:)` (lines ~125-139) is a Button that
  sets `router.openTrip = trip`, wrapped in a `.contextMenu` that today holds only a
  destructive Delete (`model.deleteTrip(trip)`).
- The trip view already edits via a sheet: `TripPlanningView.swift:129` does
  `.sheet(item: $model.destination.edit, id: \.id) { draft in TripFormView(draft: draft) }`,
  and `Trip.Draft(trip)` is the draft ctor. `Trip.Draft` has an `id`.

**Changes:**
1. On the card, add a VISIBLE ellipsis Menu (e.g. a top-trailing overlay button,
   `Image(systemName: "ellipsis.circle")`) containing "Edit" and a destructive "Delete".
   Keep the existing long-press `.contextMenu` too, mirroring the same Edit + Delete.
2. Add local presentation state on `TripsScreen`: `@State private var editingDraft: Trip.Draft?`
   and `.sheet(item: $editingDraft, id: \.id) { draft in TripFormView(draft: draft) }`.
   "Edit" sets `editingDraft = Trip.Draft(trip)`.
   (Do NOT route edit through `router.openTrip` — that opens the trip; we want the form.)

**Acceptance:**
- A visible control on each card opens the Edit Trip form for that trip.
- Delete still works from both the visible menu and long-press.
- Tapping the card body still opens the trip (unchanged).

**Watch-outs:** don't let the ellipsis hit-target steal the card's main tap — put it in a
small overlay with its own `contentShape`.

---

## Phase 3a — Header Photo moves into Edit Trip

**Goal:** the trip header-photo picker becomes a row in the Edit Trip form (existing trips
only), so it can be removed from the trip toolbar in Phase 4.

**Context:**
- `TripHeaderPickerSheet` (`Galavant/Trips/TripHeaderPickerSheet.swift:17`) is initialised
  by IDENTITY and persists straight to the DB by trip id — it does NOT bind a draft:
  ```swift
  init(tripID: Trip.ID, tripName: String, primaryRegionName: String?, hasHeader: Bool)
  ```
  So it works from the form as long as we have `draft.id` (existing trip only).
- `TripFormModel` (`Galavant/Trips/TripFormModel.swift`) holds `draft` (a `Trip.Draft` with
  `id`, `name`, `headerImage`), `isNew` (== `draft.id == nil`), DB access, and
  `sortedRegions`/`selectedRegionIDs` if you want a `primaryRegionName` (nil is fine).
- `TripFormView` (`Galavant/Trips/TripFormView.swift`) is a `Form` in a `NavigationStack`.

**Changes:**
1. In `TripFormView`, add a "Header Photo" Section, shown only when `!model.isNew` (New Trip
   has no id to persist against). A row/button that presents `TripHeaderPickerSheet` via
   `.sheet(isPresented:)`:
   ```swift
   TripHeaderPickerSheet(
     tripID: model.draft.id!,
     tripName: model.draft.name,
     primaryRegionName: /* first selected region name or nil */,
     hasHeader: model.draft.headerImage != nil
   )
   ```
2. The picker writes immediately to the DB (independent of the form's Save) — this matches
   today's toolbar behaviour, so no extra save wiring is needed. Just make sure the row's
   `hasHeader`/summary reflects `model.draft.headerImage`.

**Acceptance:**
- Editing an existing trip shows a Header Photo row that opens the Unsplash picker and
  sets/removes the trip's header.
- New Trip shows no Header Photo row (nothing to persist against yet).

**Watch-outs:** `model.draft.id` is force-unwrappable only under the `!isNew` gate — keep the
row inside that gate. Confirm `Trip.Draft.headerImage` exists (it's read at
`TripDetailContent.swift:83` and `TripCard.swift:37` on `Trip`; verify the Draft carries it —
if not, read `hasHeader` from the live trip by id).

---

## Phase 4 — Trip-view chrome declutter (do after 3a)

**Goal:** reclaim vertical space in the iPhone trip view. Remove the header photo (iPhone
only), let "+ Add" scroll away (iPhone only), and strip admin actions from the toolbar. iPad
keeps the header and its pinned Add.

**Context:**
- `TripDetailContent` (`Galavant/Trips/TripDetailContent.swift`) hosts the trip's list panel
  in BOTH layouts. A pinned `.safeAreaInset(edge: .top)` (lines 78-107) stacks THREE things:
  (a) the header photo (83-85), (b) the "+ Add" strip (88-91 via `addButton`, 113-129),
  (c) the Itinerary/Ideas segmented `Picker` (97-105).
- `addButton` is tab-sensitive: Ideas → "Add Ideas"; Itinerary → a Menu of
  "Custom Stop"/"Lodging" (`model.addCustomStopButtonTapped` / `addLodgingButtonTapped` /
  `addIdeasButtonTapped`). KEEP its behaviour; we're only relocating it.
- `TripDetailContent` is constructed at `TripPlanningView.swift:205` and `:218`; `usesColumn`
  is computed there (line 50) but NOT currently passed down.
- The two tab bodies are `TripItineraryView` (`Galavant/Trips/TripItineraryView.swift`, a
  `List`) and `TripIdeasView` (`Galavant/Trips/TripIdeasView.swift`).
- Trip toolbar items are at `TripPlanningView.swift:74-106`: Edit, Header Photo, Discuss
  (AI/chat), Start Day (conditional on `model.startDaySolverStops`), and
  `calendarReconciliationToolbarItem`.

**Changes:**
1. Thread the layout gate: `TripDetailContent(model:usesColumn:onChooseHeader:)`, passing
   `usesColumn` from both call sites in `TripPlanningView`.
2. Header photo iPhone-off: gate the header block (`TripDetailContent.swift:83-85`) on
   `usesColumn`. iPad unchanged; iPhone drops the photo band from the pinned inset.
3. "+ Add" scrolls on iPhone:
   - Extract the tab-sensitive add control into a small reusable `TripAddButton(model:tab:)`
     view (one source of truth). NOTE: new file → run `xcodegen generate` and commit the
     regenerated pbxproj.
   - iPad (`usesColumn`): keep `TripAddButton` in the pinned strip as today.
   - iPhone: remove it from the pinned inset and render it as the FIRST `Section` of the List
     inside `TripItineraryView` and `TripIdeasView` (add a `showsInlineAdd: Bool` param,
     default false; `TripDetailContent` passes `!usesColumn`). It then scrolls with content.
   - Keep the Itinerary/Ideas segmented `Picker` pinned in the inset on BOTH platforms.
   - The per-day section "+" in `TripItineraryView` (`sectionHeader`, ~line 100) is unrelated
     — leave it alone.
4. Toolbar reduction (`TripPlanningView.swift:74-106`): remove Edit, Header Photo, Start Day,
   and the calendar reconciliation item. KEEP the Discuss (AI/chat) button and the system back
   button. Remove now-dead trigger state/hosts ONLY for what moved: the header picker
   (`showingHeaderPicker` + `TripHeaderPresentationHost`) now lives in Edit Trip (Phase 3a),
   so it can go. Start Day (`showingStartDay`/`StartDayPanel`) and calendar
   (`showingCalendarReconciliation` + `CalendarReconciliationPresentationHost`) are being
   RELOCATED in Phase 3b — if 3b isn't landing in this PR, leave those two hosts/triggers in
   place (or keep them reachable) so the feature isn't stranded; remove them from the primary
   toolbar only once 3b gives them a home.

**Acceptance:**
- iPhone trip view: no header photo band; "+ Add" is the first scrollable list row and scrolls
  off; the Itinerary/Ideas switcher stays pinned; toolbar shows only Discuss + back.
- iPad trip view: header photo and pinned "+ Add" unchanged; toolbar de-cluttered the same way.
- Custom Stop / Lodging / Add Ideas all still work from the relocated control.

**Watch-outs:** `TripPlanningView`'s body is large and has hit Xcode 27 type-checker timeouts —
keep new logic in small helpers/subviews (as the file already does). Verify the pinned inset
still lays out correctly on iPhone once it carries only the `Picker`.

---

## Phase 3b — Relocate Start Day + Calendar (last)

**Goal:** give the Start-Day solver and Calendar reconciliation a home OUTSIDE the primary trip
toolbar, honouring the admin/use split. Per the accepted fork, these do NOT go into the
Draft-editing `TripFormView` — they depend on the assembled plan, which the form model doesn't
have. Instead, surface them from a context that CAN hold the live `TripPlanningModel`.

**Context:**
- `StartDayPanel(model: TripPlanningModel)` is presented via `.sheet(isPresented:
  $showingStartDay)` and is gated on `!model.startDaySolverStops.isEmpty`
  (`TripPlanningView.swift:96-104, 158-160`). It reads solver stops derived from the plan +
  structured hours (ADR-0029).
- Calendar reconciliation: `CalendarReconciliationPresentationHost(model:reconciliationModel:
  isPresented:)` wraps the trip content (`TripPlanningView.swift:62-66`), triggered by
  `calendarReconciliationToolbarItem` (~line 179). `CalendarReconciliationModel` is `@State`
  in `TripPlanningView`. It's authoritative-calendar INGEST (ADR-0034), NOT the old mirror.
- Both need the live `TripPlanningModel`/plan; neither fits `TripFormModel`.

**Direction (design latitude, but firm constraints):**
- Both flows must be reachable from an admin surface tied to the trip's live planning context.
  Simplest faithful option: keep the presentation hosts where the `TripPlanningModel` exists,
  and add an in-trip "Trip settings"/overflow entry (e.g. a single overflow menu, or a row in
  the decluttered chrome) that opens Start Day + Calendar — as long as they're OUT of the
  primary always-visible toolbar. If you can cleanly hand a `TripPlanningModel` to a
  card-launched sheet, that's preferred, but do not contort `TripFormModel` to reach the plan.
- Preserve the Start-Day conditional gate (only when `startDaySolverStops` is non-empty).
- Preserve ADR-0034 semantics (no automatic mirror-out; ingest/reconcile only).

**Acceptance:**
- Start Day + Calendar reconciliation are no longer in the primary trip toolbar but remain
  fully reachable, with the same behaviour and the same Start-Day availability gate.

**Watch-outs:** this is the fuzziest phase — confirm the chosen surface actually has the live
`TripPlanningModel`/plan in scope before wiring. Flag to Jon if the cleanest home ends up being
an in-trip overflow rather than the Trips card.
