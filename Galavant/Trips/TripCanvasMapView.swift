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

  @State private var cameraPosition: MapCameraPosition = .automatic
  @State private var visibleRegion: MKCoordinateRegion?

  /// The days the map draws: just the selected day, or all when the lens is
  /// "All" (`canvasSelectedDay == nil`).
  private var visibleDays: [TripPlanningModel.ResolvedDay] {
    if let day = model.canvasSelectedDay {
      return model.canvasDays.filter { $0.number == day }
    }
    return model.canvasDays
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
    .overlay {
      if !model.hasLocatedStops {
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
  private func dayContent(_ day: TripPlanningModel.ResolvedDay) -> some MapContent {
    let stops = model.locatedStops(forDay: day.number)
    let color = DayPalette.color(forDay: day.number)
    let route = stops.compactMap(\.coordinate)
    if route.count >= 2 {
      MapPolyline(coordinates: route)
        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
    ForEach(Array(stops.enumerated()), id: \.element.id) { index, resolved in
      if let coordinate = resolved.coordinate {
        Annotation(resolved.idea.name, coordinate: coordinate, anchor: .bottom) {
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
    let coords = model.framingCoordinates(forDay: model.canvasSelectedDay)
    if let box = MapFraming.box(for: coords) {
      cameraPosition = .region(box.region)
    } else if let region = tripRegionFrame {
      cameraPosition = .region(region)
    } else {
      cameraPosition = .automatic
    }
  }

  /// Pan to a stop selected from the timeline — but only when it isn't already in
  /// view, so tapping a pin that's already on screen doesn't yank the map. Keeps
  /// the user's current zoom.
  private func revealStop(_ id: TripIdea.ID?) {
    guard
      let id,
      let resolved = model.canvasDays.flatMap(\.stops).first(where: { $0.id == id }),
      let coordinate = resolved.coordinate
    else { return }
    if let region = visibleRegion, region.contains(coordinate) { return }
    let span = visibleRegion?.span
      ?? MKCoordinateSpan(latitudeDelta: MapFraming.singlePointDelta,
                          longitudeDelta: MapFraming.singlePointDelta)
    cameraPosition = .region(MKCoordinateRegion(center: coordinate, span: span))
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

extension TripPlanningModel.Resolved {
  /// The stop's map coordinate, when its idea has one (the canonical adapter).
  fileprivate var coordinate: CLLocationCoordinate2D? { idea.coordinate }
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

extension MKCoordinateRegion {
  /// Whether a coordinate falls within this region's span (no antimeridian wrap).
  fileprivate func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
    abs(coordinate.latitude - center.latitude) <= span.latitudeDelta / 2
      && abs(coordinate.longitude - center.longitude) <= span.longitudeDelta / 2
  }
}
