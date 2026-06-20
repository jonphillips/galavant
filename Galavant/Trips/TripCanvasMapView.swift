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
      if !model.plan.hasLocatedStops {
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
          NumberedPin(
            number: index + 1,
            color: color,
            selected: model.canvasSelectedStopID == resolved.id
          )
        }
        .tag(resolved.id)
      }
    }
  }

  // MARK: - Camera

  /// Frame the camera to the current lens: the selected day's located stops, the
  /// whole trip when "All", falling back to the trip's regions, then automatic.
  private func frameSelection() {
    let coords = model.plan.framingCoordinates(forDay: model.canvasSelectedDay)
    if let box = MapFraming.box(for: coords) {
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

/// A numbered stop marker in its day's colour; it swells and lifts when it's the
/// shared selection.
private struct NumberedPin: View {
  let number: Int
  let color: Color
  let selected: Bool

  var body: some View {
    Text("\(number)")
      .font(.caption.bold())
      .foregroundStyle(.white)
      .frame(width: 26, height: 26)
      .background(Circle().fill(color))
      .overlay(Circle().strokeBorder(.white, lineWidth: 2))
      .scaleEffect(selected ? 1.35 : 1)
      .shadow(radius: selected ? 4 : 1)
      .animation(.spring(duration: 0.25), value: selected)
  }
}

extension ResolvedStop {
  /// The stop's map coordinate, when its idea has one. Freeform stops return nil.
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
