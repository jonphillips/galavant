# ADR-0012: A region is a per-day attribute (assigned), driving idea-scope and the *empty-day* map frame — never overriding located stops

*Status: accepted — 2026-06-22*

## Context

ADR-0011 deferred "per-day region driving" with the home-base chip as the seam. The
first attempt at this ADR derived a day's region from its **base stay** (the hotel's
containing `MapRegion`) and framed the camera to that region. Built, it was wrong on
contact with real data:

- A Tokyo trip's "Tokyo Stay 1" hotel geocoded across the bay at `(35.28, 140.06)`;
  framing keyed off *where the hotel landed*, not where the day's activity was.
- The trip's regions are **coarse 1.5° scoping buckets** (the whole metro), so
  "frame to the region" zoomed *out* past the day's tightly-clustered central-Tokyo
  stops — the opposite of what's wanted once a day has real pins.

The discussion that followed reframed the whole feature. A region is not a framing
viewport derived from a hotel. It is a **planning unit the user assigns to a day**:

> "A trip includes Provence, the Loire Valley, and Normandy — three *sub-regions*,
> each associated with days. The region constrains which ideas I generate stops from,
> and is a good initial display for the day. But once I add stops to the map, framing
> should be driven by the actual stops. If my big 'Loire Valley' region is assigned
> but I'm only spending the day in Blois, zoom me in to Blois when I get up that
> morning."

Two facts fall out of that, and they invert the rejected draft:

1. **The source is explicit assignment, not derivation.** A multi-sub-region trip
   needs the planner to say "days 4–5 are the Loire," independent of where a hotel
   geocoded. This is exactly **Option 3** (a `dayNumber` on a `TripRegion`-like
   join) that the draft deferred — and the discussion shows it was the right source.
2. **The region *yields* to stops; it never overrides them.** A region is the
   **empty-day** frame (and the idea filter, and a day label). The instant a day has
   a located stop, the tight stops crop wins. A large region is therefore fine — you
   only ever *see* it framed on a day with nothing placed yet.

## Decision

**A region is a per-day attribute the planner assigns. It scopes the day's idea pool,
labels the day, and frames the *empty* day's map. Located stops always drive framing
when present.**

### Schema (small, additive — Option 3)

There is no per-day record today (days are `1…N` over `TripIdea.dayNumber`), so a new
join mirroring `TripRegion`, with a day:

```swift
@Table public struct TripDayRegion: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID        // the one real FK (rides the trip; cascade-deletes)
  public var dayNumber: Int         // 1…N
  public var regionID: MapRegion.ID // loose UUID (ADR-0007), chosen from the trip's regions
}
```

One region per day (the write path replaces any existing assignment for that day).
`regionID` is a loose, optional reference reconciled on read (ADR-0007), exactly like
`TripRegion.regionID`: a deleted region just drops out, no dangling FK.

### Framing precedence (the fix)

`frameSelection()` becomes a strict ladder:

1. **Day has located stops** → the tight stops crop (home-base pins folded in for
   visibility, ADR-0011). *Unchanged behavior; stops always win.*
2. **No located stops, day has an assigned region** → frame to that region's box
   (its exact center+delta, no padding) — the empty-day canvas / "you're in the
   Loire today" context.
3. **Otherwise** → the existing fallback: a lone located base pin, then the trip's
   region union (`tripRegionFrame`), then `.automatic`.

A located hotel on an otherwise-empty day frames to the **region**, not a street-level
zoom on the single pin (Q1) — only *stops* gate rung 1.

### Assignment UI (slice A)

Per-day assignment surfaces only when a trip has **2+ regions** (Q: "if a trip has
multiple regions, day assignment should be an option") — with 0–1 region there is
nothing to choose. The itinerary day-section header gets a region chip/menu next to
the home-base chip, picking from the trip's assigned regions (or "None"). Unassigned
days fall through to the trip-level frame; **manual assignment only** for now — no
inference from stops (Q2), revisited if it proves tedious.

### The idea filter (slice B — deferred, not this slice)

Constraining the Add-stop pool to the day's region is the meatier payoff and touches
the Add flow + ADR-0004's lens. It consumes the same `TripDayRegion` data and lands
as its own slice. Slice A (assignment + empty-day framing + day chip) ships first.

## Alternatives

| Option | Verdict |
| --- | --- |
| **(3) Explicit per-day assignment (chosen)** | Independent of hotel geocoding; models the real multi-sub-region trip (Provence/Loire/Normandy); the region becomes a deliberate planning unit (frame + filter + label). Small additive join. |
| **(1) Derive the region from the base stay's containment** | **Rejected (built and reverted).** Tied framing to where a hotel geocoded ("Tokyo Stay 1" across the bay), and *overrode* the stops crop — so a coarse 1.5° region zoomed out past a day's real pins. The override, not the derivation alone, was the core error. |
| **(2) Derive from the day's stops' centroid** | Not a *region* source at all — it's just the stops crop, which is exactly rung 1. Kept as the primary frame whenever stops exist; it can't supply the empty-day context or the filter. |
| **A full `Trip.Day` record** | Overkill now. Days stay implicit; the join carries the one per-day fact we need. |

## Why large regions stopped being a problem

The rejected draft made region size a liability (it framed *to* the region even with
stops present). Here the region only frames an **empty** day, and stops take over the
moment one exists. So a deliberately broad "Loire Valley" region is the *right* shape:
it scopes ideas across the whole valley and gives an opening frame, then the morning
you've planned Blois you're zoomed to Blois.

## Relationship to prior decisions

- **ADR-0011 (stays):** the home-base chip is no longer the framing source; the
  derived approach it seeded is rejected. The stops+base crop (rung 1) is unchanged.
- **ADR-0004 (regions as the pull lens):** per-day assignment is that lens narrowed
  from trip to day — the basis for slice B's per-day idea filter.
- **ADR-0007 (single-FK sharing):** `TripDayRegion` is a new leaf — one real FK to
  `Trip`, a loose `regionID` reconciled on read.

## Consequences

- **Schema:** new `TripDayRegion` table + CloudKit record type (additive, single FK).
- **Read-model:** `TripPlan.region(forDay:)` (pure, tested) resolves a day's assigned
  region; `MapRegion.box` exposes its framing box. Stop/stay projections untouched.
- **Canvas:** `frameSelection()` gains the empty-day region rung between the stops
  crop and the trip fallback.
- **Itinerary:** a per-day region chip/menu on the day header (2+ region trips).
- **Write path:** `TripDayRegion.setRegion(_:forTrip:day:)` (replace/clear); model
  `setDayRegion(_:forDay:)`.
- **Deferred (slice B):** per-day idea-pool filtering in the Add-stop flow.
