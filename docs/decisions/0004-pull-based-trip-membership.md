# ADR-0004: Pull-based trip membership; regions, not boards

*Status: accepted — 2026-06-10*

## Decision

1. The idea pool is the only collection. V1's Boards entity is not coming
   back; **map regions + tags** do the geographic/topical bucketing.
2. Ideas are never contained by trips. A **TripIdea join record** carries
   a status lifecycle: `considering → shortlisted → scheduled → done / skipped`.
3. Trip planning *pulls* from the pool (filtered by the trip's regions/distance);
   nothing flows into a trip automatically.
4. The shortlist is orderable (drag-to-rank) — V1's RankLists reborn as an ordering
   on the trip shortlist rather than a standalone entity.
5. **Repeat occurrences (2026-08-11 refinement):** `pull` remains idempotent —
   one pool idea earns one ordinary membership. A deliberate second visit is a
   second scheduled occurrence created from the itinerary's “Already Scheduled”
   section, with its own day/time/order; it is neither a duplicate pool idea nor a
   second shortlist vote.

## Why

The Denmark test: ideas collected over four years for a country must not flood the
eventual one-city trip, and pulling 12 of 38 ideas into a Copenhagen trip must leave
the other 26 intact in the pool for a future Jutland trip. Containment can't model
this; a status-bearing link can. Post-trip, `done`/`skipped` feed back to the pool so
future planning sees visited-state honestly.

## Carried forward from V2

- `MapRegion` for geographic bucketing and per-day region stops.
- The `Schedule` facade (`unscheduled / day / daypart(DayPart) / timed`) for
  stop timing granularity — a clean refinement over V1's flag soup. (M3c refined
  V2's original `unknown / approximated / timed / exact`: calendar dates are
  derived from the trip's start, never stored, and `.exact` was dropped — see
  docs/trip-time-model.md.)
