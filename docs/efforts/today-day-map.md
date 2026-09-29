# Effort — a daily map on Today (dogfood B2)

**Status:** Dispatched (2026-09-29) · **Summary:** add a glanceable map card to Today showing the
shown day's numbered route, its lodging base, the next event highlighted, and, on the live day, the
device's position in the frame. This is the last open slice of
[the 2026-09-11 dogfood brief](dogfood-now-and-sketch.md) (complaint 1b) and replaces that brief's
"Prompt B2" draft. Background: [ADR-0046](../decisions/0046-device-location-ephemeral-when-in-use.md)
§3–§5 (location is asked for on use, never persisted, and may join Today's union frame),
[ADR-0038](../decisions/0038-journey-today-projections-and-weather.md) (Today is a read-only
projection), and [ADR-0012](../decisions/0012-per-day-region-framing.md) (framing).

No schema change, no sync change, and no new Directions requests.

## What the card shows

A new `TodayDayMapCard` in its own file, `Galavant/Today/TodayDayMapCard.swift`. `TodayView` is
already 271 lines, so it gains only the call site. The card goes directly after the Next hero (or
`TodayNoNextCard`), before "Still to book": it answers "where is that, relative to me?" for the
card above it.

- **Route.** The shown day's located stops as `SequencePin`s numbered in `locatedStops(forDay:)`
  order, in `DayPalette.color(forDay:)`, joined by a `MapPolyline` over `routeEndpoints(forDay:)`.
  Draw it exactly as `TripCanvasMapView.dayContent` does, as straight segments. Do not derive a second
  route and do not fetch Directions geometry.
- **Lodging.** The day's `baseStays(forDay:)` as `BasePin`s. `BasePin` is `private` in
  `TripCanvasMapView.swift` today. **Move** it into its own file (`Galavant/Trips/BasePin.swift`,
  alongside `SequencePin.swift`) so both maps use one view. Don't copy it.
- **Next.** The item whose `travelEndpointID` equals `projection.next?.item.travelEndpointID` gets
  the selected treatment: `SequencePin(selected: true)` for a stop, `BasePin(selected: true)` for a
  check-in, check-out or home base. `TodayView` already reads this ID for `nextConnector`, so
  reuse it.
- **Settled stops.** Stops in `projection.doneStops` or `projection.skippedStops` draw at reduced
  opacity (around 0.4), so the eye lands on what's left.
- **Tap.** Tapping a stop or base pin that has an idea calls the same `onSelectIdea` the cards use
  (`detailIdea = idea`). Put a `Button` in the `Annotation` content. Don't use `Map` selection,
  because the map doesn't take gestures (below).
- **Hidden when empty.** If the day has no located stops and no located base, the card doesn't
  render. There is no empty map and no placeholder.

**The map is glanceable, not pannable.** Use `Map(position:interactionModes: [])` at a fixed height
(about 240pt), in the Today card styling from `TodayCards.swift`. A pannable map inside Today's
`ScrollView` takes the vertical drags meant for scrolling. It is also why there's no
`MapUserLocationButton` here: that control's follow mode needs a map that moves. A full-screen
interactive day map is a separate follow-up, recorded in `docs/open-questions.md`, and isn't part of
this dispatch.

## Device location

This dispatch doesn't touch `LocationClient`. Extend `DeviceLocationModel`
([DeviceLocationModel.swift](../../Galavant/DeviceLocationModel.swift)), whose doc comment already
names the Today map as the surface that consumes the coordinate for itself:

- Add `private(set) var coordinate: (latitude: Double, longitude: Double)?`, or a small `Equatable`
  struct if you want it observable-friendly. It is ephemeral: it's never written anywhere
  (ADR-0046 §2).
- Add `func followCoordinate() async`, which **returns immediately unless `state == .tracking`**.
  It must never be what raises the permission prompt (ADR-0046 §3). While tracking, it consumes
  `locationClient.updates()` and stores each `.located` reading. It ignores the other cases and does
  not clear a known coordinate on `.unavailable`. It ends when its task is cancelled, and it clears
  `coordinate` on exit so a stale fix can't frame a later day.
- The card holds its own `@State private var deviceLocation = DeviceLocationModel()`, the same way
  the canvas does.
- **Control.** When `.offered` or `.asking`, overlay the canvas's own "Show my location" button (the
  same glass circle, disabled while asking). Tapping it calls `locationButtonTapped()`, and that tap
  is the explicit request ADR-0046 §3 allows. When `.tracking`, draw `UserAnnotation()` and show no
  control. When `.withheld`, show nothing and say nothing (§4). Call `refresh()` on appear, as the
  canvas does.
- **Lifetime.** Run `followCoordinate()` in a `.task(id:)` keyed on "tracking **and** live". It stops
  when the user steps to a preview day, when location is withheld, or when the card leaves the
  screen. There is no stream on a preview day.

## Framing (pure, tested)

Add one pure helper to `MapFraming`
([MapFraming.swift](../../GalavantLibrary/Sources/GalavantSchema/MapFraming.swift)):

```swift
/// The day map's frame: the day's points, plus the device when it is within
/// `radius` metres of one of them. `nil` when `points` is empty.
public static func box(
  for points: [(latitude: Double, longitude: Double)],
  including device: (latitude: Double, longitude: Double)?,
  within radius: Double = todayDeviceRadius
) -> Box?
public static let todayDeviceRadius: Double = 20_000
```

- `points` is the day's located stop coordinates plus `baseCoordinates(forDay:)`, the same fold the
  canvas's day lens frames.
- **Nearby** means the device is within `radius` metres of the **nearest** day point. Twenty
  kilometres covers a day out from a base in the Dolomites. It excludes Jon's kitchen when he opens
  a live day from home before a trip. Reuse the haversine in
  `CalendarReconciliationMatching.distanceInMeters`. If you'd rather it lived somewhere neutral,
  move it (both callers use the moved one); don't copy it.
- When the device is included, the result is `box(for: points + [device])`. Otherwise it's
  `box(for: points)`. An empty `points` returns `nil`, even with a device, because the card is hidden
  then anyway.

Tests in `MapFramingTests`: a device inside the radius widens the box; a device outside the radius
leaves it identical to `box(for: points)`; a `nil` device does the same; the nearest-point rule holds
when the device is near one far-flung point but not the centre; empty points return `nil`.

**When the camera moves.** Set the camera from this box on appear, when the shown day changes, and
**once** when the first device fix arrives on the live day. Later readings move the blue dot but
never the camera. Location must not chase the camera (ADR-0046 §5), and a static card that
re-frames every few seconds would jitter. On a preview day, pass `device: nil`, so previewing day 5
from day 2 never frames the kitchen.

## Performance constraint

`TripPlanningModel.plan` rebuilds the whole read model **on every access**. That's the hazard behind
the August 2026 itinerary hang. The card must not read `planningModel.plan`. In `TodayView`, read
`plan` **once** for the card, derive `locatedStops(forDay:)`, `routeEndpoints(forDay:)` and
`baseStays(forDay:)` from that one value, and pass plain values in: the stops, route coordinates,
base stays, next endpoint ID, and settled stop IDs. The card takes no `TripPlanningModel`.

## Done when

- The card renders as above on the live day and on preview days. `BasePin` is moved rather than
  copied, and `TodayView` grows only by the call site and the single plan read.
- Package tests cover the framing helper. `GalavantTests/DeviceLocationTests` covers
  `followCoordinate()`: it doesn't start the stream unless tracking, it records `.located`
  readings, it ignores the other readings without clearing, and it clears on cancellation.
- `scripts/check-drift.sh` is green, and headless `GalavantTests` pass (`docs/verification.md`,
  because this touches an app model). Run `xcodegen generate` and commit the pbxproj if the new
  files change it.
- The completing PR:
  - adds a DONE-LOG entry.
  - sets `docs/NEXT_UP.md` to `Nothing dispatched.`
  - marks this brief **and** `dogfood-now-and-sketch.md` Done in `docs/efforts/README.md`.
    B2 was that brief's last open slice.
  - adds one line to `docs/device-passes.md`: *on a live trip day, check the Today map card's
    framing with and without location; confirm a preview day doesn't frame your position and that
    pin taps open the idea.*
