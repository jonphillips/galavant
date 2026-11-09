# Effort — Ideas along the way: saved places near a day's route, added to that day from the trip map

**Status:** Ready · **Summary:** On the trip map, with one day selected, a toggle shows saved ideas within 15 km of that
day's route. Tapping one opens it with **Add to Wed 26**, which puts it on that day. For transfer days, so Jon is reminded
of what he saved along the drive. No schema change.

**Read first:** [`trip-canvas.md`](../trip-canvas.md); ADR-0013 (pool tints: green is on this trip); jon-platform
`docs/ios/ui-and-platforms.md` § Toolbars. Jon's request, 2026-11-09, came with a screenshot: Day 6, Beaune to Talloires
by way of Baume-les-Messieurs.

## Today

- `TripCanvasMapView` draws, per visible day, `model.plan.routeEndpoints(forDay:)` as a straight `MapPolyline` (the day's
  stay, its stops, then the night's stay), plus numbered `SequencePin`s tagged with `TripIdea.ID`.
- `TripPlanningModel.ideas` already fetches the whole pool (`@FetchAll(Idea.order(by: \.name))`).
- `TripIdea.pull(ideaID:into:in:)`, `setStatus`, and `schedule(_:ideaID:tripID:in:)` put a pool idea on a day.
  `addNewIdeaToShortlist` shows the pull-and-raise pattern.
- `showDetail(_:stopID:)` presents an idea's read-only detail from the canvas.
- Map overlay buttons lose taps to the map's gestures (see the comment in `PoolMapView`), so the toggle can't sit over
  the map.

## Part 1. The corridor (`GalavantSchema`, pure)

```swift
public struct RouteCorridor: Equatable, Sendable {
  public struct Match: Equatable, Sendable {
    public var ideaID: Idea.ID
    public var distanceMeters: Double   // to the nearest point on the route
    public var progress: Double         // 0…1 along the route, for ordering
  }

  /// Ideas within `widthMeters` of the polyline through `route`, ordered by `progress`.
  public static func matches(
    route: [TravelEndpoint], ideas: [Idea], widthMeters: Double = 15_000
  ) -> [Match]
}
```

Pinned:

- **Distance is to the segment, not to the stops.** For each segment, project onto a local equirectangular plane
  centered on the segment (meters per degree of longitude scaled by `cos(latitude)`), take the nearest point clamped to the
  segment, and keep the smallest distance across segments. That's accurate enough at these scales, with no MapKit and no
  network.
- **One located point** (a day with only a stay) is a circle of `widthMeters`. **No points** gives no matches.
- **Ideas without a coordinate** never match.
- The route is the straight polyline the map draws, so "along the way" means near those lines, not near the roads. Say so
  in a doc comment.

## Part 2. Which ideas, and computed once (`TripPlanningModel`)

- **Candidates:** pool ideas with a coordinate, **minus** ideas already scheduled on the selected day (they're drawn
  already), ideas this trip has declined, and stays (`kind == .stay`; a hotel goes on the trip through Stay here, not as a
  stop).
- **Computed once per change.** Hold the matches as model state, recomputed when the selected day, the toggle, the day's
  route, or the pool changes. Never compute them from a view body or a computed property read per pin. Follow how `plan`
  rebuilds through `planSnapshot` only when its inputs change. The Aug-2026 itinerary hang came from rebuilding per access.
- **The toggle** (`showsIdeasAlongRoute`) is view-session state, off by default, and only applies when exactly one day is
  selected. On "All" or a stay lens, the layer isn't drawn and the toggle is hidden.

## Part 3. The map and the add (app target)

- **Toggle:** a toolbar button, **Ideas Along the Way** (`Icon` gets a case, for example `signpost.right`), in the trip
  tools group, shown only when one day is selected. Its on state is visible: filled symbol and selected trait.
- **Pins:** each match draws as an `Annotation` whose content is a `Button`, in the `CanvasPreviewPin` style but smaller:
  a hollow circle with the kind's symbol, neutral gray, or green when the idea is already on this trip (ADR-0013). Don't
  tag them. Idea ids aren't `TripIdea` ids, and the canvas selection is typed to those.
- **Tap:** opens the idea's detail through `showDetail`, with a bottom bar **Add to Wed 26** (the day's chip label). It
  pulls the idea if needed, raises it to `.shortlisted`, and schedules it `.day(n)` (untimed, on that day) in one
  `database.write`. Then success haptic feedback. The pin becomes a numbered stop on the day by observation, and the
  detail stays open.
- An idea already on another day shows **Move to Wed 26** instead, which re-schedules that stop. Ring members show no
  button. Their slot is the ring's.

## Tests

- `RouteCorridor`: a point beside a segment's middle, a point past a segment's end (distance to the endpoint), a point
  just outside the width, a one-point route, an empty route, an unlocated idea, and ordering by progress on a three-point
  route.
- Candidate filtering: excludes the day's own stops, declined, and stays, and keeps an idea that's on another day.
- The add: a pool idea not on the trip ends up `.scheduled` on day n. An idea on day 3 moves to day n.

## Out of scope

- Real road routes (MKDirections polylines) and a corridor that follows them.
- Placing the new stop at its route position. It lands untimed on the day, and Jon drags it into order.
- A width control, and showing the layer on "All".

## Done when

- `scripts/check-drift.sh` is green, and the app-target tests ran headless and passed (`verification.md`). Compile only, with
  no simulator walkthrough.
- The closeout carries this gate, word for word, with `--gate`:

  > **Ideas along the way (`route-ideas`).** On the iPad, TestFlight build, on the Eastern France trip. Select Wed 26 (the
  > Beaune to Talloires transfer) and turn on Ideas Along the Way. Saved places near the line show as small pins, and ones
  > already on the trip are green. Nothing far off the route shows. Tap one and Add to Wed 26: it becomes a numbered stop on
  > the day, and the itinerary shows it. Switch to All: the layer and the toggle go away. **Then judge:** Is 15 km the
  > right width? Did straight lines miss places on the actual roads? Do you want new stops slotted into route order?
