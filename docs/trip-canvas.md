# Trip canvas: map-first interaction, travel times, weather

*Design opinions agreed 2026-06-10. Feeds M3 (canvas, travel times) and M5
(weather). Sibling to `trip-time-model.md` — both are "planning feedback over
a day-relative itinerary."*

## Map as canvas, day as lens

The trip's home view is the map (Jon is a visual thinker; V1/V2 both keyed
trip interaction off maps). Rules:

- **Day chips** select a lens: one day's stops as numbered pins connected in
  sequence (polyline), camera framed to that day's region. Whole-trip view =
  all days, color-coded.
- **Detail surface** holds the day timeline + Ideas pool — two projections of
  the same selection as the map, never two separate screens. It diverges by
  platform (settled 2026-06-14, M3d): **iPhone** gets a persistent
  Apple-Maps-style **bottom sheet** (V1 used BottomSheet); **iPad** gets a
  **solid right-hand column** beside the map (V2's `TripDetailLarge` pattern) so
  the map and itinerary are manipulable at once — no translucent float-over-map,
  which only hurt readability. Branch on `horizontalSizeClass` (regular =
  column). **Edit** lives in the trip's nav toolbar on both; the context Add
  lives on the sheet/column.
- The **pool is not map-first** — it gets list+filter as the primary surface,
  map as an alternate view. Capture/browse must stay fast.
- Modern SwiftUI Map (MapPolyline/Annotation/camera APIs; check
  `swiftui-whats-new-27`) makes this far cheaper than the V1 PowerMap-era
  UIKit bridging. PowerMap's rebuild (MINING M2) should anticipate
  day-sequence rendering.

## Directions: planning feedback, not navigation

- **Travel-time connectors (M3):** MKDirections ETAs between a day's
  consecutive stops, shown in the timeline ("stop → 12 min walk → stop") and
  as the day's polylines. Derived feedback: daily walking total, and **gap
  conflicts** — a `timed`/`exact` stop pair whose gap < travel time gets
  flagged (same pure-function family as the start-day solver). Cache ETAs by
  (from, to, transport mode); MKDirections throttles. A trip can name a shared
  **Main mode of transportation**; it wins over the automatic walking/transit
  choice, while an explicit per-leg selection wins over the trip default.
- **Lodging moves:** on the All map lens, a neutral dashed line joins located
  stays in chronological order. In the itinerary, a same-day check-out →
  check-in with no scheduled stops between them gets one direct travel row. A
  day with several lodging anchors otherwise gets no guessed hotel-to-stop ETA:
  the app must not attribute a time to the wrong hotel.
- **Handoff (M3, trivial):** `MKMapItem.openInMaps(launchOptions:)` with
  directions mode per stop — finishes what V1 PowerMap's `directions`
  capability + Maps URL scheme started. Apple Maps owns turn-by-turn.
- **Out of scope forever:** in-app navigation. **Distant stretch:** day-order
  optimization suggestions (pure function over the cached ETA matrix).

## Weather: two horizons, one UI slot

Per-day chip on itinerary day headers (calendar view and timeline), data
source chosen by proximity:

- **Undated trips / >10 days out: climate normals** — typical high/low,
  precip frequency, **daylight hours** for the location + month. A decision
  input for the undated phase ("Denmark in May vs September?"), sibling to
  the start-day solver. Source: WeatherKit if its normals coverage suffices,
  else Open-Meteo climate API (free, keyless) or bundled monthly normals —
  decide at build.
- **Dated trips ≤10 days out: WeatherKit forecast** — high/low, precip,
  **sunset time** (the most actionable number: daylight budget, dinner
  timing). Free at household scale; requires the paid-membership
  entitlement (joins CloudKit on that list).
- Sunrise/sunset needs no API at all (astronomical calc) — implement
  independent of weather source.
