# ADR-0042: Freeform stops may carry inline coordinates

*Status: accepted — 2026-08-17*
*Amends: ADR-0010*

## Decision

A freeform `TripIdea` may optionally store an inline latitude and longitude. The
two nullable columns are additive fields on the already-synced `TripIdea` record;
they do not create a new table or relationship. A freeform stop with both values
participates in the existing `TripPlan` location projections, map pins, and travel
legs. A missing or partial pair remains location-less.

The custom-stop editor provides a map for placing the coordinate and a MapKit
search path for choosing a named place. The chosen location is optional and is
saved with the title and note. Search continues to use the existing injectable
place-search client; the map itself remains app-layer SwiftUI.

## Consequences

- Existing freeform stops remain unchanged and unlocated.
- `StopContent.freeform` resolves the inline coordinates, so all existing route
  and map projections gain the behavior without a parallel freeform pipeline.
- The schema change is CloudKit-compatible: two optional columns on a synced table,
  with no new record type or foreign key.
