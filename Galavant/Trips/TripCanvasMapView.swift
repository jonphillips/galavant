import GalavantSchema
import MapKit
import SwiftUI

/// The trip's home surface (M3d, docs/trip-canvas.md): a full-bleed map of the
/// scheduled stops as numbered, day-coloured pins joined by a per-day polyline.
/// The day chips pick a lens (one day, framed to its stops; "All" shows the whole
/// trip colour-coded) and the bottom sheet's timeline is the second projection of
/// the same `canvasSelectedStopID`. Mirrors `PoolMapView`'s camera idioms.
struct TripCanvasMapView: View {
  let model: TripPlanningModel
  /// The southern fraction of the map the iPhone bottom sheet covers (0 on iPad,
  /// where the detail is a side column) — so `revealStop` keeps a selected pin
  /// out from under the sheet. See `MapFraming.reveal(bottomInset:)`.
  var bottomInsetFraction: Double = 0

  @State private var cameraPosition: MapCameraPosition = .automatic
  @State private var visibleRegion: MKCoordinateRegion?

  /// The days the map draws: just the selected day, or all when the lens is
  /// "All" (`canvasSelectedDay == nil`).
  private var visibleDays: [ResolvedDay] {
    if let day = model.canvasSelectedDay {
      return model.plan.itinerary.filter { $0.number == day }
    }
    return model.plan.itinerary
  }

  var body: some View {
    @Bindable var model = model
    Map(position: $cameraPosition, selection: $model.canvasSelectedStopID) {
      ForEach(visibleDays) { day in
        dayContent(day)
      }
      baseContent
    }
    .onMapCameraChange(frequency: .onEnd) { context in
      visibleRegion = context.region
    }
    .onChange(of: model.canvasSelectedDay, initial: true) { _, _ in frameSelection() }
    .onChange(of: model.canvasSelectedStopID) { _, id in revealStop(id) }
    // Re-reveal when the sheet grows/shrinks over the map: a pin that the rising
    // sheet would swallow pans back into the clear (and `reveal` no-ops when the
    // pin is already above the sheet, so shrinking it never jerks the map).
    .onChange(of: bottomInsetFraction) { _, _ in revealStop(model.canvasSelectedStopID) }
    .overlay {
      // A located home-base pin counts as something on the map, so a trip with
      // only a hotel stay isn't a dead end (ADR-0011).
      if !model.plan.hasLocatedStops && model.plan.baseStays(forDay: nil).isEmpty {
        ContentUnavailableView {
          Icon.map.label("Nothing on the map yet")
        } description: {
          Text("Schedule stops that have a location to plot them here.")
        }
        .background(.background)
      }
    }
  }

  /// One day's polyline + numbered pins, in itinerary order, all in the day's
  /// colour.
  @MapContentBuilder
  private func dayContent(_ day: ResolvedDay) -> some MapContent {
    let stops = model.plan.locatedStops(forDay: day.number)
    let color = DayPalette.color(forDay: day.number)
    let route = stops.compactMap(\.coordinate)
    if route.count >= 2 {
      MapPolyline(coordinates: route)
        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
    ForEach(Array(stops.enumerated()), id: \.element.id) { index, resolved in
      if let coordinate = resolved.coordinate {
        Annotation(resolved.content.title, coordinate: coordinate, anchor: .bottom) {
          SequencePin(
            number: index + 1,
            color: color,
            selected: model.canvasSelectedStopID == resolved.id
          )
        }
        .tag(resolved.id)
      }
    }
  }

  /// The off-sequence home-base pins for the current lens (ADR-0011): a stay you
  /// return to each night, drawn unnumbered and *not* on any day's polyline, on
  /// every covered day-lens and on "All". A distinct neutral glyph reads as "home
  /// base," not "step N of a route." Non-selectable (no `.tag`) — `locatedStops` /
  /// `legs` and the shared stop selection stay untouched.
  @MapContentBuilder
  private var baseContent: some MapContent {
    ForEach(model.plan.baseStays(forDay: model.canvasSelectedDay)) { stay in
      if let coordinate = stay.coordinate {
        Annotation(stay.content.title, coordinate: coordinate, anchor: .bottom) {
          BasePin()
        }
      }
    }
  }

  // MARK: - Camera

  /// Frame the camera to the current lens, in precedence order (ADR-0012):
  /// 1. the lens's **located stops** → a tight crop (home-base pins folded in so a
  ///    stay stays in view, ADR-0011). Stops always win when present.
  /// 2. else, on a specific day with an **assigned region** → that region's box —
  ///    the empty-day canvas ("you're in the Loire today").
  /// 3. else the existing fallback: a lone located base pin, the trip's regions,
  ///    then automatic.
  private func frameSelection() {
    let day = model.canvasSelectedDay
    let stopCoords = model.plan.framingCoordinates(forDay: day)
    if !stopCoords.isEmpty {
      if let box = MapFraming.box(for: stopCoords + model.plan.baseCoordinates(forDay: day)) {
        cameraPosition = .region(box.region)
        return
      }
    }
    // Empty of stops: a day assigned a region frames to it (only stops gate rung 1,
    // so a lone hotel on an otherwise-empty day shows the region, not a street zoom).
    if let day, let region = model.plan.region(forDay: day) {
      cameraPosition = .region(region.box.region)
      return
    }
    if let box = MapFraming.box(for: model.plan.baseCoordinates(forDay: day)) {
      cameraPosition = .region(box.region)
    } else if let region = tripRegionFrame {
      cameraPosition = .region(region)
    } else {
      cameraPosition = .automatic
    }
  }

  /// Bring a timeline-selected stop on screen with the *minimum* pan — keep the
  /// current zoom, move only the axes that are off-screen, and don't move at all
  /// when it's already visible (so tapping pin after pin doesn't jerk the map
  /// around). Re-centring is deliberately avoided.
  private func revealStop(_ id: TripIdea.ID?) {
    guard
      let id,
      let resolved = model.plan.itinerary.flatMap(\.stops).first(where: { $0.id == id }),
      let coordinate = resolved.coordinate
    else { return }
    guard let region = visibleRegion else {
      // No settled camera yet (rare at tap time): frame on the stop to seed one.
      cameraPosition = .region(
        MKCoordinateRegion(
          center: coordinate,
          span: MKCoordinateSpan(latitudeDelta: MapFraming.singlePointDelta,
                                 longitudeDelta: MapFraming.singlePointDelta)))
      return
    }
    let box = MapFraming.Box(
      centerLatitude: region.center.latitude,
      centerLongitude: region.center.longitude,
      latitudeDelta: region.span.latitudeDelta,
      longitudeDelta: region.span.longitudeDelta)
    guard
      let panned = MapFraming.reveal(
        target: (latitude: coordinate.latitude, longitude: coordinate.longitude),
        in: box,
        bottomInset: bottomInsetFraction)
    else { return }  // already in the clear — leave the map where it is
    cameraPosition = .region(
      MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: panned.latitude, longitude: panned.longitude),
        span: region.span))
  }

  /// A region covering every map region the trip is scoped to (the corners of
  /// each), or nil if the trip has none.
  private var tripRegionFrame: MKCoordinateRegion? {
    let corners = model.tripRegions.flatMap { region -> [(latitude: Double, longitude: Double)] in
      [
        (region.centerLatitude - region.latitudeDelta / 2,
         region.centerLongitude - region.longitudeDelta / 2),
        (region.centerLatitude + region.latitudeDelta / 2,
         region.centerLongitude + region.longitudeDelta / 2),
      ].map { (latitude: $0.0, longitude: $0.1) }
    }
    return MapFraming.box(for: corners)?.region
  }
}

/// The off-sequence home-base marker: a neutral bed glyph in a soft capsule,
/// deliberately *unlike* the numbered route pins so it reads as "the place you
/// return to," not a step on the day's route. (Final styling is Jon's to tune
/// against the live map.)
private struct BasePin: View {
  var body: some View {
    Image(systemName: Icon.stay.systemName)
      .font(.caption.bold())
      .foregroundStyle(.white)
      .frame(width: 28, height: 28)
      .background(Circle().fill(.gray))
      .overlay(Circle().strokeBorder(.white, lineWidth: 2))
      .shadow(radius: 1)
  }
}

extension ResolvedStop {
  /// The stop's map coordinate, when its idea has one. Freeform stops return nil.
  fileprivate var coordinate: CLLocationCoordinate2D? { idea.flatMap(\.coordinate) }
}

extension ResolvedStay {
  /// The stay's map coordinate, when its hotel idea has one. Freeform/unlocated
  /// stays return nil and draw no base pin.
  fileprivate var coordinate: CLLocationCoordinate2D? { idea.flatMap(\.coordinate) }
}

extension MapFraming.Box {
  /// Wrap the pure framing box in a MapKit region for the camera.
  fileprivate var region: MKCoordinateRegion {
    MKCoordinateRegion(
      center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude),
      span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
    )
  }
}
