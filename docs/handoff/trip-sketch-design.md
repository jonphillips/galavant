# Design note: Sketch a trip — days × regions as a first-class planning pass

Status: **Done — shipped** (2026-09-12; Jon approved Q1–Q3, see below). What was built
is in `docs/DONE_LOG.md`. Implements the first half of
Slice E of `dogfood-now-and-sketch.md`; the second half (day header shows only time
zones) shipped as Slice 0 (#119). This note is the shape decision the Slice E prompt
asks be signed off before any UI is built.

Implements: **ADR-0012** (a region is a per-day attribute the planner assigns). This
is not a new decision — it is the missing *authoring surface* for a fact ADR-0012
already models and already pays off (empty-day framing, region-scoped idea pool). So
this is a handoff/design note, not a new ADR.

## The complaint

> "I want a way to sketch out a trip from the start with days and regions. Right now
> in a new trip all I can see are time zones."

The shape of a trip is decided *before any stop exists*: "four nights Loire, three
nights Paris, fly home day 8." That is the first thing a planner writes down, and
Galavant has no surface for it. Today the only way to record it is to assign a region
to one day at a time from a menu buried in each day-section header — the same
information entered the slowest possible way.

## The core insight: everything is already modelled — this is a view, not a table

- `TripDayRegion` (per-day region assignment, ADR-0012) — the one fact the sketch
  authors.
- `Trip.lengthInDays` — the day count.
- `MapRegion` — the regions to assign, created on the Ideas map (ADR-0044).
- `TripStay` — the nights (ADR-0011), *related to* a span but not the same thing.
- `TripPlan.region(forDay:)` already drives the empty-day map frame; `PlaceIdeaSheet`
  already scopes "Browse *Loire* Ideas" off the day's region. **The payoff is wired;
  nothing is feeding it.**

So the sketch is a **view + editor over `TripDayRegion` rows + `Trip.lengthInDays`**.
No new table. (Constraint honoured: "resist adding a table.")

## The unit is a span, not a day

A **span** is a contiguous run of days `[a…b]` carrying one optional region. Spans are
**derived, not stored** — coalesced from the per-day `TripDayRegion` rows, and
re-materialised into per-day rows on save. "Days 1–4, Loire" is one gesture that
writes four rows; it is never four menu taps.

### Pure core (`GalavantSchema`, tested)

A value type — `TripSketch` — holding the working per-day assignment and projecting
spans:

```swift
public struct TripSketch: Equatable, Sendable {
  // index 0 == day 1; count == lengthInDays. nil == unassigned.
  public private(set) var dayRegionIDs: [MapRegion.ID?]

  public init(lengthInDays: Int, dayRegions: [TripDayRegion])   // orphan days (>N) dropped
  public var lengthInDays: Int { dayRegionIDs.count }
  public var spans: [DaySpan]                                    // adjacent-equal coalesced, incl. nil runs
  public mutating func assign(_ regionID: MapRegion.ID?, toDays: ClosedRange<Int>)
  public mutating func setLength(_ n: Int)                       // grow → nil tail; shrink → drop
  public func assignments() -> [Int: MapRegion.ID]              // day → region, nil days omitted
}

public struct DaySpan: Equatable, Identifiable, Sendable {
  public let startDay: Int
  public let endDay: Int
  public let regionID: MapRegion.ID?
  public var id: Int { startDay }
  public var dayCount: Int { endDay - startDay + 1 }
}
```

Tests: span coalescing (adjacent same region merges; nil runs are spans; a region
repeated non-adjacently stays two spans), gaps (unassigned runs surface), length grow
(new days unassigned) / shrink (orphan rows dropped), `assign` clamped to `1…N` and
re-coalescing across a boundary.

### Persistence (one transaction, idempotent)

The editor works on the value type; **Done** reconciles:

```swift
try Trip.setLength(sketch.lengthInDays, tripID: tripID, in: db)          // new focused op
try TripDayRegion.replaceAssignments(sketch.assignments(),                // delete-all + insert-assigned
                                     forTrip: tripID, in: db)
```

`replaceAssignments` deletes every `TripDayRegion` row for the trip and re-inserts
only assigned days — which naturally drops cleared days *and* orphans past a shortened
length. At ≤60 days, household scale, rewriting the whole layout on save is trivial and
removes any diffing bug surface. (The existing per-day `setRegion` from the day-header
chip stays; the two write paths converge on the same rows.)

## Where it lives — reachable, and reachable *again*

A one-shot wizard you can't return to is worse than none (trips get re-shaped). So the
sketch is a **sheet reachable from two always-present entry points**:

1. **The trip settings menu** (`TripDetailContent.tripSettingsMenu`, the "···") — a
   permanent "Sketch Days" item, so the shape is always re-editable.
2. **The empty itinerary** — when nothing is scheduled *and* no spans are assigned, the
   itinerary's empty state leads with "Sketch your days" instead of a column of "No
   stops yet" rows under time-zone chips. This is where a new trip actually starts.

Not a step wired into the new-trip form: the form stays about certainty/duration/
regions, and the sketch is a richer surface that must be returnable anyway.

## The interaction

A sheet titled **Shape** (or "Sketch"), presenting the trip as a vertical list of
spans, top to bottom = day 1 → N:

- Each **span row**: the day range ("Days 1–4"), a **region chip/menu** (the trip's
  regions, "None", and "New region…"), the day count as "4 days", and an overflow for
  **Split** and **Add lodging**.
- A **Duration** control at the top (stepper, 1…60) — the same fact as the form, edited
  where it matters for shaping. Growing appends unassigned days to the last span;
  shrinking trims from the end.
- **Split** turns one span into two at a chosen day; assigning a region to the second
  half is how "days 1–4 Loire, 5–7 Paris" is built from a single starting span.
- Region assignment writes to the working value; nothing persists until **Done**
  (Cancel discards) — matching the form's save-on-confirm model.

Deliberately a **list-of-rows editor, not a drag-to-size timeline.** Drag sizing reads
well in a mockup but is fragile on the current beta (List drag-and-drop already parked
elsewhere, see KNOWN-ISSUES) and unreviewable without a device. Steppers + Split +
region menu express every span layout honestly and are fully testable. (Open to a
drag pass later once the beta drag path is trustworthy.)

## Regions — attach existing, don't create inline (Q1, signed off)

A region is a saved map viewport (center + span) created on the Ideas map (ADR-0044).
**Jon's call:** he creates regions asynchronously on the Ideas map as usual; the sketch
only needs a way to *attach* an existing region to the trip and then assign it to days.
No inline region creation.

So each span row's region menu offers the **trip's attached regions**, "None", and an
**"Attach regions…"** affordance that routes to Edit Trip's Regions picker
(`TripFormView(startOnRegions:)` — the same destination the zero-region day-header chip
already uses). When the trip has no regions attached, the sketch leads with that prompt
rather than an empty menu. Reuses the existing `TripRegion` attach path entirely — no
new region-creation code.

## Relationship to stays — offer it, don't merge it

A region span and a lodging stay are not the same model (you can be based in one hotel
and day-trip across two regions), and this note keeps them separate. But they usually
coincide, and "add lodging for these nights" is the same gesture a planner means.

**Q2 — signed off: include per-span "Add lodging."** Each span gets an "Add lodging"
action that opens the *existing* `StaySheet` seeded to the span (check-in = span start,
check-out = span end + 1), reusing the tested stay write path. No new stay logic; the
sketch just seeds the draft. An *existing* stay is shown as a hint on the overlapping
span ("🛏 Forestis") so the two surfaces agree, and the two models are never fused.

## What it does to the canvas — the handoff

With spans assigned, an empty trip stops being an empty map: each empty day already
frames to its region (ADR-0012 rung 2, already wired), and each day-section header
already shows its region chip (Slice 0). The sketch is the trip's **skeleton**; the
canvas remains where stops land. **Done** dismisses the sheet back to the planning
surface, which — with Slice A's sense of *now* — is already sitting on the live/first
day, now with regions framing the days ahead. Nothing else to build for the handoff;
it falls out of work already shipped.

## Constraints honoured

- No new table (view over `TripDayRegion` + `Trip.lengthInDays`).
- Pure span logic in `GalavantSchema` with tests (coverage, gaps, overlaps, length
  changes).
- No version suffixes (ADR-0006).
- New files under the recursive `Galavant/` path (no `project.yml` change) unless a new
  schema file lands in the SPM package — `TripSketch.swift` goes in
  `GalavantLibrary/Sources/GalavantSchema/`, already in the package's source glob.

## Build plan

1. `GalavantSchema/TripSketch.swift` + `DaySpan` — pure, with the test file.
2. `TripDayRegion.replaceAssignments(...)` + `Trip.setLength(...)` — schema ops, tested.
3. `TripSketchSheet` (UI, holding the working `TripSketch`) + sketch write/action methods
   on `TripPlanningModel` under `Galavant/Trips/`.
4. Entry points: `tripSettingsMenu` item + empty-itinerary CTA.
5. Region menu → "Attach regions…" routes to Edit Trip Regions picker (Q1); per-span
   "Add lodging" seeds the existing `StaySheet` (Q2).
6. `scripts/check-drift.sh`; branch `feat/trip-sketch`; PR. Update
   `docs/CURRENT_HANDOFF.md` and this brief's status.

## Sign-off (2026-09-12)

- **Q1 — regions:** attach existing regions only (created asynchronously on the Ideas
  map); the sketch routes to Edit Trip's Regions picker. No inline creation.
- **Q2 — lodging:** include per-span "Add lodging" reusing the existing `StaySheet`.
- **Q3 — interaction:** list-of-spans editor with Split + steppers (no drag).
