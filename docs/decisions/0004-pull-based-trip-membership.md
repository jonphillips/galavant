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

## Why

The Denmark test: ideas collected over four years for a country must not flood the
eventual one-city trip, and pulling 12 of 38 ideas into a Copenhagen trip must leave
the other 26 intact in the pool for a future Jutland trip. Containment can't model
this; a status-bearing link can. Post-trip, `done`/`skipped` feed back to the pool so
future planning sees visited-state honestly.

## Carried forward from V2

- `MapRegion` for geographic bucketing and per-day region stops.
- The `Schedule` enum (`unknown / approximated(day, daypart) / timed / exact`) for
  stop timing granularity — a clean refinement over V1's flag soup.
