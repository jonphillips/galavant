import GalavantSchema
import MapKit
import SwiftUI

struct JourneyMap: View {
  let projection: JourneyProjection
  let plan: TripPlan
  let selection: JourneySelection?

  @State private var position: MapCameraPosition = .automatic

  private var hasMapContent: Bool {
    plan.hasLocatedStops
      || !plan.baseStays(forDay: nil).isEmpty
      || projection.days.contains { plan.region(forDay: $0.dayNumber) != nil }
  }

  /// Each locality once, in trip order — one pin per region instead of one per
  /// day, which otherwise stacks identical markers on a multi-day stay.
  private var uniqueRegions: [MapRegion] {
    var seen = Set<String>()
    var result: [MapRegion] = []
    for day in projection.days {
      guard let region = plan.region(forDay: day.dayNumber) else { continue }
      if seen.insert(region.name).inserted { result.append(region) }
    }
    return result
  }

  var body: some View {
    Map(position: $position) {
      journeyPathContent
      ForEach(projection.days) { day in
        dayMapContent(day)
      }
      ForEach(uniqueRegions, id: \.name) { region in
        Marker(
          region.name,
          systemImage: "mappin.and.ellipse",
          coordinate: CLLocationCoordinate2D(
            latitude: region.centerLatitude,
            longitude: region.centerLongitude))
          .tint(.orange)
      }
      ForEach(Array(projection.stayBands.enumerated()), id: \.element.id) { index, band in
        if let coordinate = coordinate(for: band.stay) {
          Annotation(band.title, coordinate: coordinate) {
            ZStack {
              Circle().fill(StayPalette.color(forStay: index))
              Text("\(index + 1)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .scaleEffect(stayScale(band.id))
            .opacity(stayOpacity(band.id))
          }
        }
      }
    }
    .mapStyle(.standard)
    .clipShape(.rect(cornerRadius: 16))
    .overlay {
      if !hasMapContent {
        ContentUnavailableView(
          "No map points yet",
          systemImage: Icon.map.systemName,
          description: Text("Add locations to see the shape of this trip."))
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
      }
    }
    .onAppear { position = cameraPosition(for: selection) }
    .onChange(of: selection) { _, newValue in
      withAnimation(.easeInOut) { position = cameraPosition(for: newValue) }
    }
  }

  @MapContentBuilder
  private var journeyPathContent: some MapContent {
    let route = plan.lodgingPathCoordinates.map {
      CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
    }
    if route.count >= 2 {
      MapPolyline(coordinates: route)
        .stroke(.gray.opacity(0.7), style: StrokeStyle(lineWidth: 3, dash: [7, 5]))
    }
  }

  @MapContentBuilder
  private func dayMapContent(_ day: JourneyProjection.DaySummary) -> some MapContent {
    let stops = plan.locatedStops(forDay: day.dayNumber)
    let opacity = stopOpacity(day: day.dayNumber)
    let route = dayRouteCoordinates(for: day.dayNumber, stops: stops)
    if route.count >= 2 {
      MapPolyline(coordinates: route)
        .stroke(
          DayPalette.color(forDay: day.dayNumber).opacity(opacity),
          style: StrokeStyle(lineWidth: 4))
    }
    ForEach(stops) { stop in
      if let coordinate = coordinate(for: stop) {
        Annotation(stop.content.title, coordinate: coordinate, anchor: .bottom) {
          Circle()
            .fill(DayPalette.color(forDay: day.dayNumber))
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .opacity(opacity)
        }
      }
    }
  }

  private func dayRouteCoordinates(
    for dayNumber: Int, stops: [ResolvedStop]
  ) -> [CLLocationCoordinate2D] {
    guard selection == .day(dayNumber) else { return stops.compactMap(coordinate(for:)) }
    return plan.routeEndpoints(forDay: dayNumber).map { endpoint in
      CLLocationCoordinate2D(latitude: endpoint.latitude, longitude: endpoint.longitude)
    }
  }

  // MARK: Camera

  private func cameraPosition(for selection: JourneySelection?) -> MapCameraPosition {
    guard let region = focusRegion(for: selection) else { return .automatic }
    return .region(region)
  }

  /// The camera target for the current focus, falling back to the whole trip.
  private func focusRegion(for selection: JourneySelection?) -> MKCoordinateRegion? {
    switch selection {
    case .none:
      return tripRegion
    case .day(let dayNumber):
      // Include the day's lodging alongside its stops so the out-and-back drive
      // stays framed — a far-off activity shouldn't push its own hotel offscreen.
      let coordinates = plan.locatedStops(forDay: dayNumber).compactMap(coordinate(for:))
        + plan.baseStays(forDay: dayNumber).compactMap(coordinate(for:))
      if let region = Self.boundingRegion(for: coordinates) { return region }
      if let region = plan.region(forDay: dayNumber) {
        return Self.region(around: CLLocationCoordinate2D(
          latitude: region.centerLatitude, longitude: region.centerLongitude), span: 0.25)
      }
      return tripRegion
    case .stay(let id):
      if let band = projection.stayBands.first(where: { $0.id == id }),
        let coordinate = coordinate(for: band.stay) {
        return Self.region(around: coordinate, span: 0.18)
      }
      return tripRegion
    }
  }

  /// The default whole-trip frame. Deliberately built from the places the trip
  /// actually touches (stays, then stops) and only falls back to region
  /// centroids when nothing is located — a region like "Bavaria" centres on the
  /// state, which would otherwise drag the camera far from the itinerary.
  private var tripRegion: MKCoordinateRegion? {
    var points: [CLLocationCoordinate2D] = []
    for band in projection.stayBands {
      if let coordinate = coordinate(for: band.stay) { points.append(coordinate) }
    }
    for day in projection.days {
      points.append(contentsOf: plan.locatedStops(forDay: day.dayNumber).compactMap(coordinate(for:)))
    }
    if points.isEmpty {
      for day in projection.days {
        if let region = plan.region(forDay: day.dayNumber) {
          points.append(
            CLLocationCoordinate2D(
              latitude: region.centerLatitude, longitude: region.centerLongitude))
        }
      }
    }
    return Self.boundingRegion(for: points)
  }

  private static func region(
    around center: CLLocationCoordinate2D, span: CLLocationDegrees
  ) -> MKCoordinateRegion {
    MKCoordinateRegion(
      center: center, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
  }

  private static func boundingRegion(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
    guard let first = coordinates.first else { return nil }
    var minLat = first.latitude, maxLat = first.latitude
    var minLon = first.longitude, maxLon = first.longitude
    for coordinate in coordinates.dropFirst() {
      minLat = min(minLat, coordinate.latitude)
      maxLat = max(maxLat, coordinate.latitude)
      minLon = min(minLon, coordinate.longitude)
      maxLon = max(maxLon, coordinate.longitude)
    }
    let center = CLLocationCoordinate2D(
      latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
    // 1.9× leaves generous breathing room so a focused day/stay keeps its
    // surroundings for context; the floor keeps a single-point focus from
    // zooming to street level.
    let span = MKCoordinateSpan(
      latitudeDelta: Swift.max((maxLat - minLat) * 1.9, 0.12),
      longitudeDelta: Swift.max((maxLon - minLon) * 1.9, 0.12))
    return MKCoordinateRegion(center: center, span: span)
  }

  // MARK: Emphasis

  private func stopOpacity(day: Int) -> Double {
    switch selection {
    case .none: 1
    case .day(let selected): selected == day ? 1 : 0.25
    case .stay: 0.25
    }
  }

  private func stayOpacity(_ id: TripStay.ID) -> Double {
    switch selection {
    case .none: 1
    case .stay(let selected): selected == id ? 1 : 0.25
    case .day: 0.25
    }
  }

  private func stayScale(_ id: TripStay.ID) -> Double {
    if case .stay(let selected) = selection, selected == id { return 1.3 }
    return 1
  }

  private func coordinate(for stop: ResolvedStop) -> CLLocationCoordinate2D? {
    guard let latitude = stop.content.latitude, let longitude = stop.content.longitude else {
      return nil
    }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  private func coordinate(for stay: ResolvedStay) -> CLLocationCoordinate2D? {
    guard let latitude = stay.content.latitude, let longitude = stay.content.longitude else {
      return nil
    }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}
