# Handoff: Dogfood round — a sense of *now*, lodging notes, heterogeneous directions, trip sketching

Status: **In progress** — 2026-09-12. Seven slices, one new ADR. **Slices A, F, B1, C,
0, D and E shipped** (a sense of *now* on the planning surface, PR #115; Today's non-stop
events, ADR-0038 §10; device location and the blue dot, ADR-0046; heterogeneous connectors
+ the ADR-0046 §5 recentre-on-me gesture; the day-header region chip #119; stay notes #120;
the trip sketch — days × regions, `docs/handoff/trip-sketch-design.md`) and are retired
from this brief; the only remaining open slice is **B2** (daily map on Today). All
Claude-executed (Codex is on the separate "cockpit" app — unrelated to this repo's iPhone
cockpit, which is **Today**).
Summary: Jon's 2026-09-11 dogfooding pass. Six complaints that resolve into one
product theme (**the app has no sense of *now*** — not on the phone cockpit, not on
the planning surface) plus three independent defects (lodging can't take a note,
heterogeneous legs draw no directions, a new trip's only visible per-day affordance
is a time-zone picker) and one new capability (device location / blue dot).

Implements: a new ADR (device location, §Slice B) plus amendments to **ADR-0012**
(per-day regions), **ADR-0011** (stays), **ADR-0038** (Today projection), and the
travel-connector model in `TripPlan+Travel.swift`. Read those first — they carry
the *why*; this brief is the *how*.

---

## Terminology

"Cockpit" now means three things. In **this repo** it only ever means the *iPhone
cockpit* = **Today** (ADR-0038/0039, `docs/M10-EXECUTION.md`) or the *evaluation
cockpit* = **Evaluate**/`RecommendationWorkspace` (ADR-0037). Jon's separate
**"cockpit" app** is a different codebase entirely and has nothing to do with any
slice here. Everything in this brief is Galavant, and all of it is Claude's.

## What the dogfood screenshot proved

Jon's screenshot (Today, Day 12 of 16, 13:45, Dolomites) shows one day with three
separate defects visible at once:

```
Nothing else is scheduled          ← next == nil …
Your day is clear from here.

REMAINING
  ○  St Maddalena / Lunch          ← … while this is still pending
  •  Check in / Forestis   15:00   ← … and this is 75 min away
  •  Now                           ← rendered BELOW a future 15:00 row
```

…and **no directions row between St Maddalena and the Forestis check-in** — the
item-5 complaint, caught in the act.

All three share one root cause: **Today treats stops as the only real events.**
Stay boundaries and calendar constraints are woven into the timeline but are
invisible to every decision Today makes about time.

> **Fixed 2026-09-11 (Slice F, shipped — ADR-0038 §10).** The diagnosis below is kept
> because it is the *why* behind Slice C's remaining scope; rows 5b, 7a and 7b of the
> table no longer describe live code. `ItineraryTiming` is now the single clock for a
> day's rows: a connector takes the time of the event it *arrives at*, `next` admits
> any event kind, and the marker is placed against the woven stream.

Critically, this screenshot changes the diagnosis for item 5 on *this* surface. The
missing leg here is most likely **not** a connector-derivation gap — it is
`TodayProjection.rowNominalDate`, which gives a `.connector` the time of its
**preceding** row (`[preceding, following]….first`). A `.toLodging` connector between
a past lunch and a future check-in therefore inherits the *lunch's* past time and
fails `nominalDate >= now`, so `remainingTimeline` drops it — even though the same
day's itinerary may render it fine. Note the internal inconsistency: a *pending stop*
bypasses that time filter entirely (`case .pending: remaining.append`), but the
connector attached to it does not.

**Answered for Slice C:** the leg on that day *existed* and was being mis-timed, which
Slice F fixed. What remains for C is the genuine derivation gap — heterogeneous adjacent
located rows that produce no connector at all, which the four bespoke `count == 1` cases
below still can't express. Jon's "a number of places" suggests both were real.

---

## Diagnosis — each complaint traced to a cause

| # | Complaint | Root cause | Evidence |
| --- | --- | --- | --- |
| 1a | No blue dot on the trip map | The app has **no location capability at all** — no `CLLocationManager`, no `NSLocationWhenInUseUsageDescription`, no `UserAnnotation` anywhere in the tree | `grep CLLocationManager\|UserAnnotation` → zero hits; `Galavant/Info.plist` has only the Calendar key |
| 1b | No daily map on the cockpit | `TodayView` is a pure `ScrollView` of cards; no map | `Galavant/Today/TodayView.swift` |
| 2 | Can't note a lodging | The Note section is **hidden for idea-backed stays**, and the write path actively nils it | `TripPlanningStaySheets.swift:242` (`if draft.ideaID == nil`), `TripStayOperations.swift:114` (`$0.inlineNote = #bind(ideaID == nil ? note : nil)`), `TripStay.create` takes no note |
| 3a | Itinerary doesn't scroll to today | The `ScrollViewReader` only reacts to `canvasSelectedStopID`; day sections carry **no scroll anchor** and nothing ever targets a day | `TripItineraryView.swift:31–35`, `fullItinerary` |
| 3b | Lodging capsule doesn't scroll the itinerary | `toggleCanvasStay` sets `canvasSelectedStayID` only; the itinerary's `focusedDay` reads `canvasSelectedDay`, which a stay tap **clears** — so the list doesn't move at all | `TripPlanningModel.swift:238–245`, `TripDetailContent.swift` (`focusedDay: model.canvasSelectedDay`) |
| 4 | Planning surface has no sense of now | `canvasSelectedDay` is seeded to `nil` ("All") forever; the model has **no `liveDay` concept** — it exists only as a private computed property inside `TodayView` | `TripPlanningModel.swift:62`, `seedLensIfNeeded()` (seeds regions only), `TodayView.swift` `liveDay` |
| 5 | Heterogeneous directions missing | Connectors are **four bespoke special cases**, not a general rule over adjacent located rows. Each has `count == 1` guards that silently return nil | `TripPlan+Travel.swift` — `lodgingToStopRoute`, `arrivalToStopRoute`, `stopToLodgingRoute`, `stayTransfer` |
| 5b | Same leg missing **in Today** specifically | `rowNominalDate` gives a connector its **preceding** row's time, so a leg into a future check-in inherits a past stop's time and is filtered out of `remaining` | `TodayProjection.swift` `.connector` case — `[preceding, following]….first` |
| 6 | New trip shows only time zones | `DayRegionMenu` is gated on `model.tripRegions.count >= 2`; `DayTimeZoneMenu` is **ungated**. A new trip has 0–1 regions, so the per-day header renders exactly one chip: the time zone | `TripItineraryRows.swift:22–27` |
| 7a | "Nothing else is scheduled" with a pending stop and a 15:00 check-in on screen | `TodayProjection.next` matches `case .stop` only, and `isUpcoming` returns **false** for any stop without a nominal date (a floating Anytime stop, ADR-0033) as well as for past ones | `TodayProjection.swift:190–200`, `isUpcoming` at `:414` |
| 7b | "Now" rendered below a future 15:00 check-in | `nowMarkerIndex(in: stops, …)` scans **stops only**; all stops past ⇒ `at == stops.count` ⇒ the marker is appended at the very end of `items`, after the check-in row | `TripPlan.swift:610`, and the trailing append at `:604` |

Item 6's cause is worth restating, because it is a one-line gate producing a
first-run impression: on a brand-new trip the only thing a day offers you is a
list of IANA time-zone identifiers.

---

## Slices, models, and sequencing

House rule (ROADMAP preamble): conservative and Opus-leaning; Sonnet only where
there's an in-tree pattern to clone, guarded by tests and the drift gate.

| Slice | Work | Model | Depends on | Branch |
| --- | --- | --- | --- | --- |
| **0** | Quick win: un-gate the day-region chip, demote the time-zone chip | **Sonnet 5** | — | `fix/day-header-region-chip` |
| **A** | A sense of *now* on the planning surface: `liveDay` in the model, day lens seeded to today, itinerary auto-scroll, lodging-capsule → day scroll | **Opus 5** | — | `feat/planning-sense-of-now` |
| **B1** | `LocationClient` + blue dot on the trip canvas map (+ new ADR) | **Opus 5** | — | `feat/device-location` |
| **B2** | Daily map card on the Today cockpit | **Sonnet 5** | B1 | `feat/today-day-map` |
| **C** | Generalize travel connectors to any adjacent located waypoints | **Opus 5** | — | `fix/heterogeneous-connectors` |
| **D** | A note on any lodging stay, idea-backed or freeform | **Sonnet 5** | — | `feat/stay-notes` |
| **E** | Sketch a trip: days × regions as a first-class planning pass | **Opus 5** | Slice 0, Slice A | `feat/trip-sketch` |

**Why these models.** C is the highest-risk item on the list — it rewrites the pure
core that four surfaces (itinerary rows, canvas polylines, Today, Journey) all read,
under an existing test suite that encodes the current special cases; getting the
dedup and `.kind` classification wrong produces phantom or doubled legs that look
plausible. A and E are product-design calls (what does "now" mean on a planning
surface you're also using six months early?) rather than mechanical edits. B1 adds a
privacy-sensitive capability, touches entitlements/plist/XcodeGen, and lands on
MapKit and CoreLocation API surface that is past training cutoff — check current
docs and the `swiftui-whats-new-27` skill rather than recall. D and B2 clone
patterns that already exist in-tree (the freeform-stay note path; `PlaceSelectionMap`
+ `DayPalette`), and Slice 0 is a two-line gate change.

Haiku isn't right for any of these — every slice touches either the pure core under
test or a product decision.

**Sequencing.** 0, D, B1 are independent — run them concurrently. C is independent of
those too; F (shipped) already answered its scope question — the lodging leg on that day
existed and was being *mis-timed*, so C's remaining work is genuinely the heterogeneous
pairs that draw no connector at all. B2 follows B1. E follows A and 0 (all three touch
`TripItineraryView`/`SectionHeader`; E is the one that reshapes them).

**Verification for every slice:** `scripts/check-drift.sh` (SwiftLint --strict,
`swift test --package-path GalavantLibrary`, and the `build-for-testing` pass that
compiles + links `GalavantUITests`). Branch + PR, never push to `master`. If you
touch targets or add files outside the recursive `Galavant/` source path, update
`project.yml` and run `xcodegen generate`.

---

# Prompts

Each prompt is self-contained — hand it to a cold session. All of them assume:

```
Repo: ~/code/galavant/galavant   (NOT ~/code/galavant/galavantios — that's V1)
Read first: AGENTS.md, docs/STYLE.md, the ADRs named in the prompt.
```

---

## Prompt 0 — Day header: show the region chip, demote the time zone (Sonnet 5)

> In `~/code/galavant/galavant`, fix a first-run impression problem in the trip
> itinerary's per-day section header.
>
> **Read first:** `AGENTS.md`, `docs/decisions/0012-per-day-region-framing.md`,
> `docs/decisions/0041-calendar-dogfood-amendments.md` (the per-day time-zone
> feature is deliberate — you are demoting it, not deleting it).
>
> **Problem.** `Galavant/Trips/TripItineraryRows.swift:22–27` renders the day
> header's chip row as:
>
> ```swift
> if model.tripRegions.count >= 2 {
>   DayRegionMenu(day: day, model: model)
> }
> DayTimeZoneMenu(day: day, model: model)
> ```
>
> On a new trip `tripRegions` is empty or has one entry, so the region chip is
> hidden and the **only** per-day affordance a user sees is a time-zone picker
> listing every IANA identifier. That is the first thing Jon meets on a fresh trip.
>
> **Change.**
> 1. Show `DayRegionMenu` whenever the trip has **one or more** regions. With
>    exactly one region the menu still earns its place — it's how you say "day 3 is
>    in this region" and drive the empty-day map frame (ADR-0012).
> 2. When the trip has **zero** regions, render the chip in an unassigned state
>    whose tap routes to the existing region picker (`TripRegionPicker`, reachable
>    from Edit Trip) rather than showing nothing. Keep the label honest — "Set
>    region" reading as tertiary, as it does today.
> 3. Gate `DayTimeZoneMenu` so it appears only when it can matter: the trip is
>    `.dated` **and** (a per-day override is already set for that day **or** the
>    trip's regions span more than one time zone). Otherwise hide it. Do not remove
>    the type or the model methods — ADR-0041 keeps them.
>
> **Out of scope:** the sketch surface (a separate slice), any schema change, any
> change to `TripDayRegion`/`TripDayTimeZone` write paths.
>
> **Verify:** `scripts/check-drift.sh`. Branch `fix/day-header-region-chip`, land
> via PR. Do not run the simulator — Jon reviews on device.

---

## Prompt A — A sense of *now* on the planning surface (Opus 5)

> In `~/code/galavant/galavant`, give the trip planning surface a sense of *now*.
>
> **Read first:** `AGENTS.md`, `docs/STYLE.md`, `docs/trip-canvas.md`,
> `docs/decisions/0038-journey-today-projections-and-weather.md`,
> `docs/decisions/0011-accommodations-as-stays.md`.
>
> **The complaint, in Jon's words:** *"When the trip is ON, everything needs a sense
> of now. Not just the phone cockpit, but the planning surface as well. Don't make me
> scroll to the day and select it."* Plus: the itinerary should scroll to today
> automatically, and tapping a lodging capsule should scroll the itinerary to the
> first day of that stay.
>
> **Current state.**
> - `TripPlanningModel.canvasSelectedDay` (`Trips/TripPlanningModel.swift:62`) is
>   seeded to `nil` ("All") and never learns the date. `seedLensIfNeeded()` seeds
>   regions only.
> - The only live-day logic in the app is a **private computed property inside
>   `Today/TodayView.swift`** (`liveDay`), built on
>   `TodayProjection.tripDay(containing:tripStartDate:in:)` — which already lives in
>   the pure core and returns nil when the trip isn't underway.
> - `TripItineraryView`'s `ScrollViewReader` (`Trips/TripItineraryView.swift:31–35`)
>   only reacts to `canvasSelectedStopID`. Day sections carry no scroll anchor.
> - `toggleCanvasStay` (`TripPlanningModel.swift:238`) sets `canvasSelectedStayID`
>   and **clears** `canvasSelectedDay`; `TripDetailContent` passes
>   `focusedDay: model.canvasSelectedDay`, so a capsule tap moves the map lens and
>   leaves the list exactly where it was.
>
> **Build.**
> 1. **Promote `liveDay` to the model.** Expose it on `TripPlanningModel`, derived
>    from the pure `TodayProjection.tripDay` helper, nil when the trip is undated or
>    not underway. `TodayView` should then read the model's value instead of keeping
>    its own copy. Take the clock from `@Dependency(\.date)`, not `Date.now` — note
>    that `TripItineraryView` currently passes a bare `Date.now` into
>    `itineraryItems(...)` in two places; route those through the model's clock as
>    part of this change so the behavior is testable.
> 2. **Seed the day lens to today, once.** Extend the first-appear seeding so a trip
>    that is underway opens on its live day rather than "All". Do not fight the user:
>    seed once, and never re-seed over an explicit selection. A trip that is not
>    underway keeps today's behavior. Coordinate with
>    `pickInitialSheetTabIfNeeded()` — an active trip should land on Itinerary.
> 3. **Mark today in `DayChipBar`.** The live day's chip needs to read as *today* at
>    a glance, distinct from "selected". Your call on the treatment; keep it legible
>    against the existing `DayPalette` colour dot and the selected capsule state.
> 4. **Auto-scroll the whole-trip itinerary to the live day.** Give each day section
>    a stable scroll anchor and scroll to the live day on appear (animation off for
>    the initial placement — it should already be there, not glide there). Preserve
>    the existing stop-selection scroll.
> 5. **Lodging capsule → itinerary.** Tapping a capsule in `LodgingCapsuleBar` must
>    move the list to the stay's `checkInDay`, not only the map. Decide the cleanest
>    semantics and say which you chose in the PR body — either the stay lens sets the
>    focused day to `checkInDay` (simple, but conflates the two lenses), or the
>    itinerary keeps the whole-trip list under a stay lens and scrolls to the first
>    covered day (preserves "a stay spans days", costs a branch in
>    `TripDetailContent`). The second is probably right — a stay is a span, and
>    collapsing it to one day loses the thing the lens exists to show — but make the
>    call deliberately.
>
> **Constraints.** The now-marker row already exists in `TripPlan.itineraryItems`;
> don't build a second one. Keep pure logic in `GalavantSchema` with tests — model
> state changes belong in `TripPlanningModel`, day-derivation belongs in the core.
> No new dependency.
>
> **Out of scope:** the Today cockpit's own layout, the daily map (Slice B2), the
> trip sketch surface (Slice E).
>
> **Verify:** `scripts/check-drift.sh`, plus unit tests for the live-day derivation
> and the seeding rule (including: undated trip, trip in the past, trip in the
> future, day 1 and day N boundaries). Branch `feat/planning-sense-of-now`, land via
> PR. Update `docs/CURRENT_HANDOFF.md` / `docs/DONE_LOG.md` per house rule.

---

## Prompt B1 — Device location and the blue dot — SHIPPED

The ADR the prompt asked for is
[`docs/decisions/0046-device-location-ephemeral-when-in-use.md`](../decisions/0046-device-location-ephemeral-when-in-use.md);
what was built is in `docs/DONE_LOG.md`. Two notes for B2, the dependent slice:

- The seam it consumes is `LocationClient.updates` (`Galavant/LocationClient.swift`) — an
  `AsyncStream<LocationReading>`. The Info.plist key is already in `project.yml`.
- The canvas holds **no live location session**: `UserAnnotation` draws the dot from
  MapKit's own updates, and `DeviceLocationModel` consumes the stream only until the
  authorization question is answered. B2 needs the *coordinate*, so it starts its own
  stream and owns its lifetime.

---

## Prompt B2 — A daily map on the Today cockpit (Sonnet 5, or hand to Codex)

> **Dependency: Slice B1 must be merged first** (this consumes its `LocationClient`
> and its Info.plist key).
>
> In `~/code/galavant/galavant`, add a map of the current day to the **Today** view —
> the on-the-ground iPhone cockpit, `Galavant/Today/TodayView.swift`.
>
> **Read first:** `AGENTS.md`, `docs/decisions/0038-journey-today-projections-and-weather.md`,
> `docs/decisions/0039-today-execution-completion-skip-defer.md`,
> `docs/M10-EXECUTION.md`, and `Galavant/Trips/TripCanvasMapView.swift` (the idioms
> to mirror, not to copy wholesale).
>
> **Problem.** Today is a `ScrollView` of cards with no spatial view at all. On the
> ground, the one thing you want alongside "what's next" is *where that is relative
> to where I am*.
>
> **Build.** A day-map card in the Today stack showing:
> - today's located stops in itinerary order, numbered, in that day's `DayPalette`
>   colour, with the day's polyline — reuse `plan.locatedStops(forDay:)` and
>   `plan.routeEndpoints(forDay:)`; do not derive a second route,
> - the day's lodging base pin, matching the canvas's `BasePin` treatment,
> - the user's location (`UserAnnotation`, from Slice B1),
> - the **next** stop visually distinguished — Today's whole job is "what's next",
>   and the map should answer it without reading the cards.
>
> Frame the camera on the union of today's stops plus the user's location when it's
> available and nearby; fall back to the existing `MapFraming` helpers otherwise.
> Tapping the card's next-stop pin should select the same idea the cards select
> (`onSelectIdea`), so the map and the cards stay one surface.
>
> **Respect the preview mode.** `TodayView` renders any trip day via its day stepper;
> when `isPreviewing` is true the map shows that day's route but **not** a live
> "you are here" framing — previewing day 5 from day 2 shouldn't fly the camera to
> Jon's kitchen.
>
> **Constraints.** No new projection type and no persistence — Today is a read-only
> projection over `TripPlan` (ADR-0038) and this card must stay that way. No second
> Directions polling loop; `TodayModel` deliberately avoids one. Keep `TodayView`
> from growing — it's already 263 lines and the repo has been actively splitting
> these files (PRs #104–110); put the card in `TodayCards.swift` or its own file.
>
> **Verify:** `scripts/check-drift.sh`. Branch `feat/today-day-map`, land via PR.

---

## Prompt C — Directions between *any* adjacent located things — SHIPPED

The four hand-written lodging cases (`lodgingToStopRoute`, `arrivalToStopRoute`,
`stopToLodgingRoute`, `stayTransfer`) collapsed into one rule over the day's ordered
located-waypoint chain (`TripPlan.routeLegs`, derived from the shared
`orderedEventRows`). `TravelConnector.Kind` is now a classification of the leg's
endpoints, not a gate on whether it exists; the weave's insertion bookkeeping and the
`function_body_length` waiver are gone. Gaps 1–5 (overlapping stays, a located
constraint's transparency, checkout-with-no-arrival, stop-before-mid-day-check-in,
unlocated stays) each landed with a named test in
`GalavantSchemaTests/HeterogeneousConnectorTests.swift`. The **recentre-on-me** gesture
(ADR-0046 §5) shipped alongside. What's built is in `docs/DONE_LOG.md`.

---

## Prompt D — A note on any lodging stay (Sonnet 5)

> In `~/code/galavant/galavant`, let a lodging stay carry a note whether or not it's
> backed by a pool hotel.
>
> **Read first:** `AGENTS.md`, `docs/decisions/0011-accommodations-as-stays.md`,
> `docs/decisions/0026-idea-description-vs-notes.md`.
>
> **Problem.** `TripStay.inlineNote` exists but is treated as *freeform-stay-only*
> content. Three places enforce that:
> - `Galavant/Trips/TripPlanningStaySheets.swift:241` — the Note section is wrapped in
>   `if draft.ideaID == nil`, so a hotel from the pool has no note field at all.
> - `GalavantSchema/TripStayOperations.swift:114` — `edit` writes
>   `$0.inlineNote = #bind(ideaID == nil ? note : nil)`, actively **erasing** a note
>   the moment a stay gains an idea.
> - `TripStay.create` (idea-backed) takes no `note` parameter at all.
>
> Result: Jon books a real hotel and has nowhere to put "ask for a room away from the
> lift, parking is €18/night, breakfast until 10."
>
> **Change.** A stay note is the **trip party's note about this stay** and applies to
> both kinds. The pool `Idea`'s own notes remain separate and untouched — one is "this
> hotel", the other is "our stay at it" (the ADR-0026 distinction).
>
> 1. **Do not rename the column.** `inlineNote` stays `inlineNote` — a `@Table` column
>    rename is a CloudKit schema change and this needs none. Update its doc comment to
>    say what it now means, and note the name is historical.
> 2. `TripStay.create` accepts an optional note; `TripStay.edit` persists the note
>    unconditionally.
> 3. Resolve the note into the read model for idea-backed stays too —
>    `GalavantSchema/TripPlan.swift:186` and `:260` currently surface it only through
>    the freeform `.stay(title:note:)` content case. Check how `ResolvedStay.content`
>    is built for an idea-backed stay and make the note reachable there without
>    breaking the `StopContent` enum's contract.
> 4. `StaySheet`: show the Note section always. Keep the placeholder honest for a
>    hotel — the freeform "Optional details" is fine, but a hotel note is more likely
>    a reservation detail.
> 5. **Show it.** A note that only exists in the edit sheet isn't a feature. Surface
>    it, truncated, on the rows that already render a stay: `CheckRow` and
>    `HomeBaseRow` in `Trips/TripItineraryRows.swift`, and `TodayTonightCard` in
>    `Today/TodayCards.swift` — tonight's lodging note is exactly the thing you want on
>    the phone at 6pm.
>
> **Out of scope:** booking metadata (confirmation numbers, URLs — `BookingFieldsDraft`
> already exists for stops and the stay-booking seam is explicitly deferred in
> `TripStay`'s doc comment to the trip-time-model work), images, any new column.
>
> **Verify:** `scripts/check-drift.sh`, with schema tests covering: create idea-backed
> with a note; edit a freeform stay into an idea-backed one and confirm the note
> **survives** (it currently does not — that's the regression test); clear a note back
> to nil. Branch `feat/stay-notes`, land via PR.

---

## Prompt E — Sketch a trip: days × regions — SHIPPED

The trip sketch — a view + editor over `TripDayRegion` + `Trip.lengthInDays` (no new
table, ADR-0012) — shipped. Pure `TripSketch`/`DaySpan` span core in `GalavantSchema`;
`TripSketchSheet` reachable from the trip settings menu and the empty-itinerary CTA;
per-span "Add lodging" reuses `StaySheet`; regions are attached (not created) inline via
Edit Trip's Regions picker. Design + Jon's Q1–Q3 sign-off:
`docs/handoff/trip-sketch-design.md`. What's built is in `docs/DONE_LOG.md`.

---

## Notes for whoever sweeps this file

Retire slices from this brief as they ship (per the `CURRENT_HANDOFF.md` rule — an
entry that is done gets deleted, not annotated). When the last slice lands, mark this
brief **Done** in `docs/handoff/README.md` and move the summary to `docs/DONE_LOG.md`.
