import Foundation
import GalavantSchema
import MapKit
import SwiftUI

/// What the map is currently focused on. Tapping a day or a stay elsewhere on
/// the surface flies the (otherwise fixed) map to the related pins; tapping the
/// same element again clears the focus back to the whole trip.
enum JourneySelection: Equatable {
  case day(Int)
  case stay(TripStay.ID)
}

/// The iPad anticipation surface for one trip. Journey is read-only and regular
/// width by design; Today is the compact/iPhone execution surface.
struct JourneyView: View {
  let planningModel: TripPlanningModel

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dismiss) private var dismiss
  @State private var model = JourneyModel()
  @State private var projection: JourneyProjection?
  @State private var renderedPlan: TripPlan?
  @State private var selection: JourneySelection?

  private struct ProjectionInput: Equatable {
    var plan: TripPlan
    var tripStartDate: Date?
    var travelTimes: [LegKey: [TransportMode: TravelTime]]
  }

  private var projectionInput: ProjectionInput {
    ProjectionInput(
      plan: planningModel.plan,
      tripStartDate: planningModel.trip?.startDate,
      travelTimes: planningModel.travelTimes)
  }

  var body: some View {
    Group {
      if horizontalSizeClass == .regular {
        if let projection, let renderedPlan {
          journey(projection, plan: renderedPlan)
        } else if projectionInput.tripStartDate != nil {
          ProgressView("Preparing Journey…")
        } else {
          ContentUnavailableView(
            "Journey is not available",
            systemImage: "calendar.badge.clock",
            description: Text("Set this trip’s start date before opening Journey."))
        }
      } else {
        ContentUnavailableView(
          "Journey is an iPad view",
          systemImage: "ipad",
          description: Text("Use Today on iPhone for the on-the-go trip view."))
      }
    }
    // The trip name is the in-content hero (`JourneySummaryHeader`), so the nav
    // bar carries no title of its own — an inline empty title leaves just Done.
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Done") { dismiss() }
      }
    }
    .task(id: projectionInput) {
      let input = projectionInput
      guard let tripStartDate = input.tripStartDate else {
        projection = nil
        renderedPlan = nil
        await model.loadWeather(for: nil)
        return
      }
      let resolved = JourneyProjection.resolve(
        from: input.plan,
        tripStartDate: tripStartDate,
        travelTimes: input.travelTimes)
      guard !Task.isCancelled else { return }
      projection = resolved
      renderedPlan = input.plan
      await model.loadWeather(for: resolved)
    }
  }

  /// The screen is a fixed frame: the header and stay rail pin to the top, the
  /// day spine scrolls on the left, and the map holds still on the right so
  /// scrolling never drags it away to geography the trip never touches.
  private func journey(_ projection: JourneyProjection, plan: TripPlan) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 16) {
        JourneySummaryHeader(trip: planningModel.trip, summary: projection.summary)
        Spacer(minLength: 16)
        // The header row's right side — empty until now — carries the image band;
        // the map keeps its own full-height column below, untouched.
        JourneyImagePanel(
          projection: projection, plan: plan, model: model, selection: selection)
          .frame(maxWidth: 520, alignment: .trailing)
      }
      .padding(.horizontal)
      .padding(.top, 8)
      JourneyStayRail(projection: projection, selection: $selection)

      HStack(alignment: .top, spacing: 16) {
        ScrollViewReader { proxy in
          ScrollView {
            JourneyDaySpine(projection: projection, model: model, selection: $selection)
              .padding(.horizontal)
              .padding(.bottom, 24)
          }
          // Tapping a lodging capsule jumps the day spine to that stay's first
          // day, so the rail and the spine stay in sync as you browse stays.
          .onChange(of: selection) { _, newValue in
            guard case .stay(let id) = newValue,
              let band = projection.stayBands.first(where: { $0.id == id })
            else { return }
            withAnimation(.easeInOut) {
              proxy.scrollTo(band.nights.lowerBound, anchor: .top)
            }
          }
        }
        JourneyMap(projection: projection, plan: plan, selection: selection)
          .frame(minWidth: 300, idealWidth: 400, maxWidth: 480)
          .frame(maxHeight: .infinity)
          .padding(.trailing)
          .padding(.bottom)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(.systemGroupedBackground))
    .safeAreaInset(edge: .bottom) {
      if let attribution = model.attribution {
        HStack {
          Spacer()
          WeatherAttributionLink(attribution: attribution)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
      }
    }
  }
}

private struct JourneySummaryHeader: View {
  let trip: Trip?
  let summary: JourneyProjection.TripSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(trip?.name ?? "Journey")
        .font(.largeTitle.bold())
      Text(
        "\(summary.startDate.formatted(date: .abbreviated, time: .omitted)) – "
          + "\(summary.endDate.formatted(date: .abbreviated, time: .omitted))")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Label("\(summary.nightCount) nights", systemImage: "moon.stars")
        Text("·")
        Label("\(summary.stayCount) stays", systemImage: Icon.stay.systemName)
        if summary.transferDayCount > 0 {
          Text("·")
          Label {
            Text(
              summary.transferDayCount == 1
                ? "1 transfer day" : "\(summary.transferDayCount) transfer days")
          } icon: {
            Image(systemName: TransportMode.driving.systemImageName)
          }
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      if !summary.regionNames.isEmpty {
        Text(regionSummary)
          .font(.subheadline)
          .foregroundStyle(.tint)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(trip?.name ?? "Journey"), \(summary.nightCount) nights, \(summary.stayCount) stays")
  }

  /// The locality run, capped so a long multi-region trip never overflows the
  /// header — the map and day spine carry the full geography.
  private var regionSummary: String {
    let shown = summary.regionNames.prefix(3)
    let overflow = summary.regionNames.count - shown.count
    return shown.joined(separator: " · ") + (overflow > 0 ? " · +\(overflow) more" : "")
  }
}

private struct JourneyStayRail: View {
  let projection: JourneyProjection
  @Binding var selection: JourneySelection?

  private var bands: [JourneyProjection.StayBand] {
    projection.stayBands.filter { !$0.nights.isEmpty }
  }

  var body: some View {
    if !bands.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Where you’ll stay")
          .font(.headline)
          .padding(.horizontal)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .top, spacing: 10) {
            ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
              JourneyStayChip(
                band: band,
                color: StayPalette.color(forStay: index),
                isSelected: selection == .stay(band.id))
              .contentShape(RoundedRectangle(cornerRadius: 12))
              .onTapGesture { toggle(band.id) }
            }
          }
          .padding(.horizontal)
        }
      }
    }
  }

  private func toggle(_ id: TripStay.ID) {
    selection = selection == .stay(id) ? nil : .stay(id)
  }
}

/// A stay's colour, shared by its "Where you'll stay" chip and its numbered map
/// pin so a lodging reads as one colour across the surface. Reuses `DayPalette`'s
/// distinct cycle, keyed by stay order rather than day.
private enum StayPalette {
  static func color(forStay index: Int) -> Color {
    DayPalette.colors[((index % DayPalette.colors.count) + DayPalette.colors.count)
      % DayPalette.colors.count]
  }
}

private struct JourneyStayChip: View {
  let band: JourneyProjection.StayBand
  let color: Color
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label {
        Text(headline)
          .font(.caption.weight(.semibold))
      } icon: {
        Image(systemName: Icon.stay.systemName)
      }
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      Text(band.title)
        .font(.caption2)
        .lineLimit(2)
        .opacity(0.9)
    }
    .frame(width: 190, alignment: .leading)
    .frame(minHeight: 52, alignment: .topLeading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .foregroundStyle(.white)
    .background(color.gradient, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(.white, lineWidth: isSelected ? 3 : 0)
    }
    .shadow(color: isSelected ? color.opacity(0.5) : .clear, radius: 6)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(band.regionName ?? band.title), \(band.nightCount) nights")
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
  }

  private var headline: String {
    let nights = "\(band.nightCount) night\(band.nightCount == 1 ? "" : "s")"
    return band.regionName.map { "\($0) · \(nights)" } ?? nights
  }
}

private struct JourneyDaySpine: View {
  let projection: JourneyProjection
  let model: JourneyModel
  @Binding var selection: JourneySelection?

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 10) {
      Text("The trip")
        .font(.headline)
      ForEach(projection.days) { day in
        JourneyDayCard(
          day: day,
          model: model,
          isSelected: selection == .day(day.dayNumber))
        .id(day.dayNumber)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { toggle(day.dayNumber) }
      }
    }
  }

  private func toggle(_ dayNumber: Int) {
    selection = selection == .day(dayNumber) ? nil : .day(dayNumber)
  }
}

private struct JourneyDayCard: View {
  let day: JourneyProjection.DaySummary
  let model: JourneyModel
  let isSelected: Bool

  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Day \(day.dayNumber)")
          .font(.headline)
        Text(day.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        if let locality = day.locality {
          Text(locality)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.tint)
        }
        if !day.stops.isEmpty { disclosureChevron }
      }

      if day.stops.isEmpty {
        Text(day.locality != nil ? "At leisure" : "A quiet day")
          .foregroundStyle(.secondary)
      } else if isExpanded {
        // Expanded: the day's stops in order, each with its header image.
        VStack(alignment: .leading, spacing: 8) {
          ForEach(day.stops) { stop in
            JourneyStopRow(stop: stop, thumbnail: model.thumbnail(forIdea: stop.ideaID))
          }
        }
      } else {
        Text(day.stopTitles.joined(separator: "  ·  "))
          .font(.body)
          .lineLimit(2)
        if let definingStop = day.definingStop, day.stopCount > 1,
          definingStop.title != day.stopTitles.first {
          Text("Defining stop: \(definingStop.title)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      if day.isTransfer, let from = day.transferFrom, let to = day.transferTo {
        HStack(spacing: 6) {
          Image(systemName: day.transferMode?.systemImageName ?? TransportMode.driving.systemImageName)
          Text("\(from.title) → \(to.title)")
          if let time = day.transferTime, let mode = day.transferMode {
            Text("· \(time.formatted(mode: mode))")
          }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12), in: Capsule())
      }

      if !day.weatherAnchors.isEmpty {
        HStack(spacing: 8) {
          ForEach(Array(day.weatherAnchors.enumerated()), id: \.offset) { index, _ in
            if let weather = model.summary(for: day.dayNumber, anchorIndex: index) {
              JourneyWeatherBadge(summary: weather)
            }
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(
          isSelected ? Color.accentColor : Color.gray.opacity(0.25),
          lineWidth: isSelected ? 2 : 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(dayAccessibilityLabel)
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
  }

  /// The expand/collapse control for a day's stops. Its own button, so tapping it
  /// reveals the itinerary rows without also toggling the card's map selection.
  private var disclosureChevron: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
    } label: {
      Image(systemName: "chevron.right")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .contentShape(Rectangle())
        .padding(.leading, 4)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isExpanded ? "Hide stops" : "Show stops")
  }

  private var dayAccessibilityLabel: String {
    var pieces = ["Day \(day.dayNumber)"]
    if let locality = day.locality { pieces.append(locality) }
    if day.stopCount > 0 { pieces.append("\(day.stopCount) stops") }
    if day.isTransfer { pieces.append("transfer day") }
    return pieces.joined(separator: ", ")
  }
}

/// One stop inside an expanded day card: its header image (or kind glyph) beside
/// the title and kind. The same 44-pt fit-not-fill footprint the Ideas list uses,
/// so a letterboxed logo never crops to an unreadable zoom.
private struct JourneyStopRow: View {
  let stop: JourneyProjection.StopDigest
  let thumbnail: Data?

  var body: some View {
    HStack(spacing: 10) {
      leadingImage
      VStack(alignment: .leading, spacing: 1) {
        Text(stop.title)
          .font(.subheadline)
          .lineLimit(2)
        if let kind = stop.kind {
          Text(kind.label)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var leadingImage: some View {
    if let thumbnail, let image = UIImage(data: thumbnail) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(width: 44, height: 44)
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    } else {
      Image(systemName: stop.kind?.systemImage ?? "mappin.and.ellipse")
        .foregroundStyle(.secondary)
        .frame(width: 44, height: 44)
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }
}

private struct JourneyWeatherBadge: View {
  let summary: WeatherSummary

  var body: some View {
    Group {
      if let daily = summary.daily {
        Label {
          Text("\(daily.highTemperature, format: .measurement(width: .narrow)) / \(daily.lowTemperature, format: .measurement(width: .narrow))")
        } icon: {
          Image(systemName: daily.symbolName)
        }
      } else if let current = summary.current {
        Label {
          Text(current.temperature, format: .measurement(width: .narrow))
        } icon: {
          Image(systemName: current.symbolName)
        }
      }
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(.quaternary, in: Capsule())
  }
}

private struct JourneyMap: View {
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
    let stopCoordinates = stops.compactMap(coordinate(for:))
    let opacity = stopOpacity(day: day.dayNumber)
    let route = dayRouteCoordinates(day: day, stopCoordinates: stopCoordinates)
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

  /// The polyline a day draws. For the focused day it becomes an out-and-back
  /// loop from that day's lodging — out through the activities and home again —
  /// so an hour's drive to a single stop is visible, not hidden. Other days keep
  /// the plain stop-to-stop line so the whole-trip overview stays legible.
  private func dayRouteCoordinates(
    day: JourneyProjection.DaySummary, stopCoordinates: [CLLocationCoordinate2D]
  ) -> [CLLocationCoordinate2D] {
    guard selection == .day(day.dayNumber), !stopCoordinates.isEmpty,
      let lodging = plan.baseStays(forDay: day.dayNumber).compactMap(coordinate(for:)).first
    else { return stopCoordinates }
    return [lodging] + stopCoordinates + [lodging]
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
