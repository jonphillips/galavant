# M10 execution — Today View V1 (ADR-0038)

Implementation plan for the **Today** surface — the on-the-ground iPhone cockpit — and
the **shared weather foundation** it introduces. Journey follows in a later slice sequence
and is out of scope here (Today first, dogfood, then Journey — ADR-0038 §8).

Authority: [ADR-0038](decisions/0038-journey-today-projections-and-weather.md). Read it
first. The governing restraint: **Today is a read-only projection of `TripPlan`; no new
persisted trip concepts.** All logic that can be pure is pure and lives in `GalavantSchema`;
SwiftUI stays thin; WeatherKit is the only new dependency and is device-only verified.

## Ground truth (verified 2026-08-15 — the reuse surface)

The projection is built almost entirely from facts that already exist:

- `TripPlan.itineraryItems(forDay:travelTimes:effectiveModes:now:tripStartDate:stays:) -> [ItineraryItem]`
  (`GalavantSchema/TripPlan.swift:413`) already weaves stops, `TravelConnector`s, and the
  `.nowMarker`, and also emits `.checkIn` / `.checkOut` / `.homeBase` / `.calendarConstraint`
  (`TravelConnector.swift:116-146`). Today projects **over this stream**, it does not rebuild it.
- `Schedule` (`GalavantSchema/Schedule.swift:13`): `.timed(day, start:end:)` (`"HH:mm"` strings),
  `.daypart(day, part)`, `.day` (displays "Anytime"), `.unscheduled`.
- Times are day-relative; convert to wall-clock via `TripPlan.nominalDate` + `tripStartDate`.
- `TripStay` (`GalavantSchema/TripStay.swift:30`): `checkInDay`/`checkOutDay`/`nights` (Range)
  → "Night 2 of 3".
- `TripDayRegion` (ADR-0012) + `MapRegion.centerLatitude/centerLongitude` → locality heading
  and a weather-anchor fallback coordinate. Package is MapKit-free — coords are raw `Double?`.
- `TravelConnector.Kind`: `.betweenStops` / `.fromLodging` (hotel→first stop) / `.betweenLodgings`
  (hotel→hotel). ETA value type `TravelTime {seconds, meters}`.
- `DirectionsClient` (`Galavant/Trips/DirectionsClient.swift:9`) + ETA cache in
  `TripPlanningModel` (`travelTimes: [LegKey: [TransportMode: TravelTime]]`).
- Open-in-Maps handoff: `TripItineraryView.swift:416` (`openInMaps(connector:)`).
- `IdeaKind` (`GalavantSchema/IdeaKind.swift`): includes `outdoorTrail`/`beach`/`park`/`activity`
  → drives weather sensitivity without a new field.

## Slice sequence

### Slice 1 — the pure Today core (no WeatherKit, fully unit-tested) ← **build first**

**Home:** `GalavantLibrary/Sources/GalavantSchema/` (new file(s), e.g. `TodayProjection.swift`,
`WeatherAnchor.swift`, `LeaveBy.swift`). Tested in the existing `GalavantSchema` test target.

Deliver three pure value types + their derivations, all functions of an already-built
`TripPlan` (+ injected `now: Date`, `tripStartDate: Date`, and the existing `travelTimes`
map). No I/O, no MapKit, no WeatherKit.

1. **`TodayProjection`** — the finished read model the iPhone view renders:
   - `dayContext`: resolved date, `TripDayRegion` locality (fallback: derive from the day's
     stay/stops without persisting), day number.
   - `next`: the next actionable `ItineraryItem` from today's stream (first point stop at/after
     `now`; skip `.nowMarker`/boundary rows), carrying its `LeaveBy` result and a
     `WeatherAnchor` request.
   - `remaining`: the post-`now` timeline with completed items collapsed into an
     "Earlier today · N" summary; connectors remain first-class between items.
   - `tonight`: the covering `TripStay` as "Night k of n" via `nights`.
   - `tomorrow`: next day's locality + the `.betweenLodgings` transfer leg's `WeatherAnchor`-less
     ETA request (orientation only — do not reproduce tomorrow's itinerary).
   - A **no-weather** shape is the default: every weather-bearing field is optional and the type
     is complete and renderable with all of them nil.

2. **`LeaveBy`** — the honesty ladder (ADR-0038 §5):
   - `.timed(day, start, _)` → `.clock(Date)` = `start(converted via tripStartDate) − ETA − buffer`.
   - `.daypart` → `.approximate(TravelTime)` ("~12 min drive").
   - `.day` (Anytime) / `.unscheduled` → `.awayBy(TravelTime)` ("12 min away").
   - ETA comes from the passed-in `travelTimes` for the relevant leg (`.fromLodging` when the next
     item is the day's first stop, else `.betweenStops`). No fabricated precision.

3. **`WeatherAnchor`** — the pure "which coordinate, which window" decision (ADR-0038 §4).
   **Returns raw `lat/lon` + a time window; never fetches.**
   - Coordinate ladder: located weather-sensitive `Idea` (`IdeaKind` outdoor set) → `TripDayRegion`
     center → covering `TripStay` coordinate → other located day geography → `nil` (omit).
   - Window ladder mapped to `Schedule`: `.timed(start,end)`→interval; `.timed(start,nil)`→start
     hour + display window; `.daypart`→portion-of-day; `.day`/`.unscheduled`→daily.
   - Expose whether the anchor is "weather-sensitive" so the view can vary emphasis.

**Acceptance (Slice 1):**
- New tests in the `GalavantSchema` suite cover: next-item selection across `now` positions;
  earlier-today collapse count; leave-by for each `Schedule` case (clock vs approximate vs away);
  the full weather-anchor coordinate ladder incl. the omit case; tonight "Night k of n"; tomorrow
  orientation. All deterministic (injected `now`/`tripStartDate`).
- `TodayProjection` builds and renders complete with **all weather fields nil** (the >10-day-out
  and unresolved-geography cases).
- No import of WeatherKit, MapKit, or SwiftUI in these files. `swift test` green (this target is not
  FoundationModels-linked, so the host gap does not apply).

### Slice 2 — the `WeatherClient` dependency (app layer; device-only verified)

**Home:** app target (needs `CLLocation`/WeatherKit). New `@Dependency` `WeatherClient`, seamed
exactly like `DirectionsClient`.

- `WeatherClient`: `(coordinate, window, granularity) async throws -> WeatherSummary`. Dumb —
  converts the anchor's raw lat/lon to `CLLocation`, calls WeatherKit, decodes to a small
  `WeatherSummary` (current/daily/hourly-interval + optional alert + `expiration`).
- Device-local cache only, keyed on `metadata.expirationDate` + rounded coordinate. Never persisted
  to SQLite/CloudKit.
- `previewValue`/`testValue` return canned summaries so Slice 1's projection + Slice 3's view render
  in previews with no network.
- WeatherKit capability/entitlement added to the app target; Apple Weather attribution affordance
  (ADR-0038 §9).

**Acceptance:** on a real device, requesting a known coordinate returns a decoded `WeatherSummary`;
cache respects `expirationDate`; attribution visible. (Device-only per the FM/sim caveats — no
simulator Apple-services verification.)

### Slice 3 — the Today SwiftUI surface (iPhone)

**Home:** app target, new `TodayView` + subviews. Renders the Slice-1 `TodayProjection`, fills
weather from Slice-2 `WeatherClient`.

- Day-context header; small ambient "here now" weather.
- **NEXT hero** with disproportionate weight: title, schedule-derived detail, `LeaveBy` string,
  **Directions** (reuse `openInMaps(connector:)`), optional trail-map thumbnail from known coords,
  and — for a weather-sensitive anchor — the **destination-time** forecast on the hero (ADR-0038 §4;
  this is the correction to the concept rendering).
- Vertical remaining timeline: "Earlier today · N" collapsed, connectors first-class, `.nowMarker`
  inline.
- **Tonight** (stay span) + **Tomorrow** (one orientation card).
- **No-weather is first-class**: hero and rows are complete and handsome with every forecast absent.

**Acceptance:** on the preferred review sim (iPad Pro 13" is the standing review target, but Today is
iPhone — install/launch on an iPhone sim for layout), the view renders from a real trip's projection
with mocked weather; the no-weather state looks finished; Directions launches Apple Maps.

### Slice 4 — runtime coordination (fold into 3 if small)

One tick source drives the live clock; weather served from the `expiration` cache; next-leg ETA on
its own bounded freshness policy (more aggressive than the planning prewarm). Goal: no polling storm
as the clock advances (ADR-0038 §7).

## Explicitly deferred (do not build in M10 Today V1)

Journey surface; per-region photography; AI trip themes; severe-weather/minute-precip advisory;
device GPS / Core Location ("you are here"); climatology; auto-entry into Today on launch. See
ADR-0038 §8.

## Codex handoff

**Slices 2–4** are device/UI/dogfooding work — point Codex (or work) at the slice sections above;
they need Jon-in-the-loop verification that a prompt can't substitute for. Do **not** pre-write
prompts for them.

**Slice 1** is pure, crisp, and testable — ideal for a cold-start agent. Self-contained prompt:

> **Task: Slice 1 of M10 (ADR-0038) — the pure Today projection in `GalavantSchema`.**
> Branch `feat/m10-today-slice1-core` off `main`. Work the local checkout on that branch and land
> via PR to `main` (no worktrees; one editor at a time; serialize with other agents).
>
> Read `docs/decisions/0038-journey-today-projections-and-weather.md` and
> `docs/M10-EXECUTION.md` (Ground truth + Slice 1) first. Add pure value types +
> derivations to `GalavantLibrary/Sources/GalavantSchema/` — `TodayProjection`, `LeaveBy`,
> `WeatherAnchor` — each a function of an already-built `TripPlan` plus injected
> `now: Date` and `tripStartDate: Date` and the existing `travelTimes: [LegKey: [TransportMode: TravelTime]]`.
> **Hard constraints:** no `import WeatherKit`, no `import MapKit`, no `import SwiftUI` in these
> files; coordinates stay raw `Double`; `WeatherAnchor` returns coordinate + time window and never
> fetches; the projection must build and render with every weather field `nil`. Reuse
> `TripPlan.itineraryItems(…now:…tripStartDate:…)` — do not rebuild the itinerary stream. Map
> `LeaveBy` and `WeatherAnchor` onto the real `Schedule`/`IdeaKind`/`TravelConnector.Kind` cases
> exactly as listed in the plan.
>
> Add tests to the existing `GalavantSchema` test target covering every ladder branch and the
> nil-weather shape (see Slice 1 acceptance). Run `swift test` for the schema target and get it
> green. Do not touch the app target, WeatherKit, or the project file. Open a PR titled
> "M10 Slice 1 — pure Today projection core (ADR-0038)" summarizing the new types and test coverage.
