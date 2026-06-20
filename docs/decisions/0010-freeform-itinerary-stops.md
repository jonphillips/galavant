# ADR-0010: Freeform itinerary stops — a stop is not always a pulled idea

*Status: accepted — 2026-06-20*

## Context

Some itinerary entries aren't pool ideas: "lunch break", "train to Aarhus",
"check in — confirmation #...". ADR-0004 framed every stop as a pulled `Idea`
(a `TripIdea` join row with a real `ideaID`). That assumption is too narrow:
a trip's day has structural entries that were never collected in the pool and
never will be.

A freeform stop wants **everything** the itinerary pipeline already gives an
idea-backed stop — day placement, the `Schedule` granularity facade, intra-day
ordering, the now-marker, drag-rank, the to-be-scheduled bucket. It differs in
exactly one dimension: **what the stop is** (a pulled pool idea vs. an inline
label), and as a downstream consequence it has no coordinates — so no map pin
and no travel-leg, which the canvas/leg code already handles by dropping any
stop without coordinates.

## Decision

**A stop is the trip's own record; joining to a pool idea is the common case,
not the definition.** A `TripIdea` row may stand alone as a freeform stop.

1. `TripIdea.ideaID` becomes **optional** (`Idea.ID?`). It remains a loose UUID,
   not a SQL FK — unchanged under the single-FK sharing rule (ADR-0007); the
   trip is still the one real parent.
2. Two inline columns carry a freeform stop's content: **`inlineTitle: String?`**
   and **`inlineNote: String?`**. They are populated iff `ideaID == nil`.
3. The read-model resolves "what is this stop" into an impossible-states enum
   (STYLE §3), replacing `ResolvedStop.idea: Idea`:

   ```swift
   public enum StopContent: Equatable, Sendable {
     case idea(Idea)                            // ideaID set + found in pool
     case freeform(title: String, note: String?) // ideaID nil + inlineTitle present
   }
   ```

   `TripPlan.resolve` maps each entry:
   - `ideaID` set **and** found in the pool → `.idea(idea)`
   - `ideaID == nil` **and** `inlineTitle` present → `.freeform(...)`
   - `ideaID` set **but missing** from the pool → `nil` (orphan, dropped —
     the existing read-time reconciliation, unchanged)
   - `ideaID == nil` **and** no title → `nil` (malformed; `reportIssue`)

   Coordinate/title access moves from `stop.idea.latitude` / `.title` to
   `stop.content.coordinate` / `.content.title`. A `.freeform` stop has no
   coordinate, so it falls out of `legs`/`framingCoordinates`/canvas pins for
   free — exactly right ("lunch break" draws no route).
4. **Lifecycle:** freeform stops skip `considering → shortlisted`. They are born
   `.scheduled` — placed on a day, or in the to-be-scheduled bucket
   (`dayNumber == nil`). They never appear in the shortlist/considering piles.

## Why option A (one record), not a sibling `FreeformStop`

A sibling record keeps `TripIdea`'s name literally accurate, but forces **every**
itinerary projection (`itinerary`, `scheduled`, `toBeScheduled`,
`itineraryItems`, the now-marker, drag-rank) to merge and re-sort two
homogeneous streams on the same key — duplicated timing logic for zero
behavioral difference. A freeform stop *is* behaviorally a stop that happens to
have no idea; the difference belongs at the resolve step, not in a parallel
record and a parallel pipeline. The enum also improves the existing model: today
`ResolvedStop` silently couples "has an entry" with "has an idea"; `StopContent`
makes that an explicit, total type.

## Relationship to ADR-0004

ADR-0004 stands; this refines its point 2. "Ideas are never contained by trips,
a TripIdea join carries the status lifecycle" remains true **for idea-backed
stops** — the pull-based membership story is unchanged. ADR-0010 only adds that
a `TripIdea` row need not reference an idea at all. The pull/shortlist/considering
machinery is exactly the part freeform stops opt out of (they're born scheduled).

## Naming

The `TripIdea` Swift type and CloudKit record type keep their names. Renaming a
synced record type is a CloudKit schema migration not worth a naming nicety;
the doc comment is broadened to "a trip's stop — usually a pulled pool idea,
optionally a freeform inline entry."

## Consequences

- Schema migration: `ideaID` nullable + two new nullable text columns. Additive
  and CloudKit-friendly (new optional fields).
- ~13 `stop.idea.*` call sites across `TripPlan`, `TripItineraryView`,
  `TripIdeasView`, `TripPlanningSheets`, `TripCanvasMapView` move to
  `stop.content.*` — mechanical.
- New write path: create a freeform stop directly on the itinerary (an "Add a
  break / freeform stop" affordance alongside "Add stop" which pulls from the
  shortlist). Editing inline title/note in place.
- Accommodations (BACKLOG) stays a separate design — stays span nights and are
  not a `.timed` point stop; ADR-0010 does not cover them.
