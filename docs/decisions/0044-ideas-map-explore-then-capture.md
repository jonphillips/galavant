# ADR-0044: Ideas map POIs explore before capture

*Status: accepted — 2026-08-21*

*Supersedes the POI-tap capture behavior implied by ADR-0013; ADR-0013's
shopping-surface and list/map layout remain unchanged.*

## Decision

On the Ideas map, tapping an Apple Maps point of interest is a read-only
exploration step. Galavant retains the resolved `MKMapItem` and presents Apple's
native rich place detail: a sheet on compact/iPhone and a popover on
regular/iPad. Nothing is written at this step.

Create Idea is a Galavant-owned adjacent action. Apple's native detail card is a
closed presentation surface, so Galavant does not rebuild it or inject content
into it; a conspicuous floating action starts the existing capture path with
`Place(mapItem:)` and `MapPlaceCapture().draft(for:)`. The shared
`PlaceSelectionMap` remains immediate-capture by default so Calendar and other
existing callers keep their current tap-to-assign behavior.

## Consequences

- The map resolver retains the framework `MKMapItem` at the presentation seam and
  keeps `Place` as the value boundary for capture and calendar assignment.
- Explore-first presentation is opt-in and modeled as a presentation-policy enum;
  the selected map item is transient view state and is never persisted.
- Native-card/action coexistence requires a real iPhone and iPad device check;
  compile verification cannot establish that the floating action remains
  reachable beside both native presentations.
