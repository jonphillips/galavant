# Handoff — sectioned itinerary reorder (inline boundaries + cross-day drag)

**Status:** designed, not built. Spike-first (the overload is unproven on this beta).
**Precondition base:** `feat/itinerary-drag-reorder-day-lens` (single-collection
day-lens reorder, working on device — see below). Build on top of that branch.

## Goal

Two things, one mechanism:

1. **Inline day-anchored boundary rows.** In the day lens
   (`TripItineraryView.focusedDayList`), hotel check-in/out, calendar constraints,
   home-base, and the now-marker must render as **static rows at their exact time
   position**, interleaved with stops — and must **not** move when a stop is dragged.
2. **Cross-day drag.** In `fullItinerary`, drag a stop from one day to another.

Both require the **sectioned** reorder container,
`reorderContainer(for: ResolvedStop.self, in: SectionID.self)` +
`reorderable(collectionID:)`. A "section" is a **contiguous run of stops** with no
day-anchored row between them; boundary rows render statically *between* sections.
For cross-day, a section is a whole day. Same overload, two groupings.

## Why this shape (the constraint)

iOS 27 `reorderable()` needs **one contiguous `ForEach`** per collection. You cannot
drop a static, non-reorderable row into the middle of a reorderable `ForEach`. The
day lens currently works around this by *folding* every non-stop item into the next
stop cell (`focusedDayCells` → `FocusedDayStopCell.leading/trailing`). That glues
day-anchored events to a stop: lifting the first stop lifts the hotel check-in and
the calendar row with it (screenshot 2026-08-19; see KNOWN-ISSUES). The sectioned
container is the sanctioned way to interleave static rows with reorderable runs.

Read the skill first: `swiftui-whats-new-27/references/reorderable.md`, the
"Sections and multiple collections" section. The `in:` type is the **section
model's `ID`**, and `difference.destination.collectionID` tells you the destination
section.

## Two gotchas already paid for (do not rediscover)

1. **No custom `dragContainer`.** `reorderContainer` is already its own drag
   container and drop destination. A custom `dragContainer(for:)` turns the reorder
   into a plain item-drag whose drop **always resolves back to the source's original
   slot** — a silent no-op that still fires the DB write (reads as "snaps back").
   We hit this exactly. Gate pickup in the persistence layer (already done: the model
   no-ops a non-`.day` source), never with a `dragContainer`.
2. **No long-press `.contextMenu` inside a reorderable row.** It competes with the
   reorder lift (both long-press) and the drag won't commit on a quick gesture. The
   connector row's mode picker is now a tap `Menu` for this reason. Keep any per-row
   menu tap-triggered.

## What already works (the base, don't regress)

Single-collection day-lens reorder is **confirmed on device** (beta 5 `27A5237l`):
- `TripItineraryView.focusedDayList`: `List` + `ForEach(stops).reorderable()` +
  `.reorderContainer(for: ResolvedStop.self)` closure that applies the difference and
  calls `model.reorderDayStops(_:on:moving:)`.
- Persistence: `TripPlanningModel.reorderDayStops` → `TripIdea.reorderDayStops`
  (writes `dayRank`; leading Anytime rows get negative ranks, ADR-0033). Pickup is
  gated to Anytime `.day` stops by the model guard.
- Read order: `TripIdea.orderedDayStops` sorts by `(effectiveIntraDaySort, dayRank)`.

## Build plan

**Spike 0 (prove the overload before investing).** Smallest possible sectioned
container: two hard-coded sections of stops with a static `Text("—")` between them,
`reorderable(collectionID:)` on each, `reorderContainer(for:in:)` on the `List`.
Confirm on device that (a) a stop lifts, and (b) a drop in the *other* section lands
(watch for `System gesture gate timed out`). If it fails here, it's the beta's
`List`-as-destination wall — stop, and coordinate with
`yes-chef/docs/decisions/ADR-0055-*` (their D3 lands the first sectioned data point).
Do not build the full timeline until Spike 0 is green.

**Slice 1 — day lens inline boundaries.** Replace the folding in `focusedDayList`:
- Build an ordered `[Segment]` from `plan.itineraryItems(forDay:)`, where a `Segment`
  is either `.boundary(ItineraryItem)` (calendar/checkIn/checkOut/homeBase/nowMarker)
  or `.stopRun([ResolvedStop])` (a maximal run of consecutive `.stop` items, with each
  stop's *trailing* travel connector still folded into that stop's cell — connectors
  are genuinely stop-attached and are fine to keep).
- Render boundaries as static rows; render each `.stopRun` as a
  `ForEach(run).reorderable(collectionID: run.id)`.
- `.reorderContainer(for: ResolvedStop.self, in: <RunID>.self)`. On drop, route by
  `difference.destination.collectionID` to the destination run, rebuild the affected
  run(s)' order, and persist. Intra-day moves still land on
  `model.reorderDayStops`; a move *across* a run (past a boundary) is still same-day —
  it only changes `dayRank`, so the same primitive works once you recompose the full
  day order from all runs.
- Keep only-Anytime pickup gating.

**Slice 2 — cross-day (`fullItinerary`).** Section = day (`ItineraryDay.number`).
`reorderContainer(for: ResolvedStop.self, in: Int.self)`. A drop whose
`destination.collectionID` differs from the source's day is a **day move**: set the
stop's `dayNumber` to the destination day and rerank within that day. Reuse the
`StopMenu` "Move to Day" write path for the `dayNumber` change, then `reorderDayStops`
for placement. (`StopMenu` Move-to-Day / To-Be-Scheduled remains the fallback.)

## Device verification (owed each slice — no simulator for this)

- Drag an Anytime stop within a run → persists, no snap-back.
- Drag a stop across a boundary (Slice 1) / across days (Slice 2) → lands, persists.
- Lift a stop adjacent to a hotel check-in / calendar row → the boundary row **stays
  put** (the bug this fixes).
- Timed stops: confirm the intended affordance (currently liftable-but-no-op; decide
  whether to visually mark them non-reorderable).
- No `System gesture gate timed out` in the console.

## Files

- `Galavant/Trips/TripItineraryView.swift` (`focusedDayList`, `focusedDayCells`,
  `fullItinerary`, `focusedDayStopCell`).
- `Galavant/Trips/TripPlanningModel+Scheduling.swift` (`reorderDayStops`; add a
  day-move op for Slice 2).
- `Galavant/Trips/ReorderDifference+Apply.swift` (single-collection helper today;
  sectioned routing needs the `collectionID`-aware path — add, don't break the
  existing overload the trips backlog + shortlist depend on).
- Reference: `docs/KNOWN-ISSUES.md` ("List drag-and-drop" entry), ADR-0033.
