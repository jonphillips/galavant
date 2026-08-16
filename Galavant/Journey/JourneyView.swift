import Foundation
import GalavantSchema
import MapKit
import SwiftUI

/// The iPad anticipation surface for one trip. Journey is read-only and regular
/// width by design; Today is the compact/iPhone execution surface.
struct JourneyView: View {
  let planningModel: TripPlanningModel

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var model = JourneyModel()

  private var tripStartDate: Date? { planningModel.trip?.startDate }

  private var projection: JourneyProjection? {
    guard let tripStartDate else { return nil }
    return JourneyProjection.resolve(
      from: planningModel.plan,
      tripStartDate: tripStartDate,
      travelTimes: planningModel.travelTimes)
  }

  var body: some View {
    Group {
      if horizontalSizeClass == .regular {
        if let projection {
          journey(projection)
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
    .navigationTitle("Journey")
    .navigationBarTitleDisplayMode(.large)
    .task(id: projection) {
      await model.loadWeather(for: projection)
    }
  }

  private func journey(_ projection: JourneyProjection) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        JourneySummaryHeader(trip: planningModel.trip, summary: projection.summary)
        JourneyStayBands(projection: projection)

        HStack(alignment: .top, spacing: 20) {
          JourneyDaySpine(projection: projection, model: model)
            .frame(maxWidth: .infinity, alignment: .leading)
          JourneyMap(projection: projection, plan: planningModel.plan)
            .frame(minWidth: 280, idealWidth: 360, maxWidth: 460, minHeight: 540)
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 20)
    }
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
        Label("\(summary.dayCount) days", systemImage: "calendar")
        Text("·")
        Label("\(summary.stayCount) stays", systemImage: Icon.stay.systemName)
        if !summary.regionNames.isEmpty {
          Text("·")
          Text(summary.regionNames.joined(separator: " · "))
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(trip?.name ?? "Journey"), \(summary.dayCount) days")
  }
}

private struct JourneyStayBands: View {
  let projection: JourneyProjection

  var body: some View {
    if !projection.stayBands.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Stays")
          .font(.headline)
        ForEach(projection.stayBands) { band in
          HStack(spacing: 2) {
            ForEach(projection.days) { day in
              JourneyStayBandCell(
                day: day,
                band: band,
                isCovered: band.nights.contains(day.dayNumber))
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(band.title), \(band.nights.count) nights")
        }
      }
    }
  }
}

private struct JourneyStayBandCell: View {
  let day: JourneyProjection.DaySummary
  let band: JourneyProjection.StayBand
  let isCovered: Bool

  var body: some View {
    let ordinal = band.nights.distance(
      from: band.nights.startIndex,
      to: day.dayNumber)
    VStack(alignment: .leading, spacing: 2) {
      if isCovered, day.dayNumber == band.nights.first {
        Text(band.title)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
      }
      if isCovered {
        Text("Night \(ordinal + 1) of \(band.nights.count)")
          .font(.caption2)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    .padding(.horizontal, 8)
    .background(
      isCovered ? Color.accentColor.opacity(0.16) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8))
    .overlay(alignment: .leading) {
      if isCovered {
        Capsule()
          .fill(.tint)
          .frame(width: 3)
      }
    }
  }
}

private struct JourneyDaySpine: View {
  let projection: JourneyProjection
  let model: JourneyModel

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 10) {
      Text("The trip")
        .font(.headline)
      ForEach(projection.days) { day in
        JourneyDayCard(day: day, model: model)
      }
    }
  }
}

private struct JourneyDayCard: View {
  let day: JourneyProjection.DaySummary
  let model: JourneyModel

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
      }

      if day.stops.isEmpty {
        Text("A quiet day")
          .foregroundStyle(.secondary)
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
        Label("\(from.title) → \(to.title)", systemImage: "arrow.right")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.orange)
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
        .strokeBorder(.quaternary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(dayAccessibilityLabel)
  }

  private var dayAccessibilityLabel: String {
    var pieces = ["Day \(day.dayNumber)"]
    if let locality = day.locality { pieces.append(locality) }
    if day.stopCount > 0 { pieces.append("\(day.stopCount) stops") }
    if day.isTransfer { pieces.append("transfer day") }
    return pieces.joined(separator: ", ")
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

  var body: some View {
    Map {
      journeyPathContent
      ForEach(projection.days) { day in
        dayMapContent(day)
      }
      ForEach(projection.days) { day in
        if let region = plan.region(forDay: day.dayNumber) {
          Marker(
            "Day \(day.dayNumber) · \(region.name)",
            systemImage: "mappin.and.ellipse",
            coordinate: CLLocationCoordinate2D(
              latitude: region.centerLatitude,
              longitude: region.centerLongitude))
            .tint(.orange)
        }
      }
      ForEach(projection.stayBands) { band in
        if let coordinate = coordinate(for: band.stay) {
          Marker(band.title, systemImage: Icon.stay.systemName, coordinate: coordinate)
            .tint(.gray)
        }
      }
    }
    .mapStyle(.standard)
    .clipShape(.rect(cornerRadius: 16))
    .overlay {
      if !plan.hasLocatedStops && plan.baseStays(forDay: nil).isEmpty {
        ContentUnavailableView(
          "No map points yet",
          systemImage: Icon.map.systemName,
          description: Text("Add locations to see the shape of this trip."))
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
      }
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
    let coordinates = stops.compactMap(coordinate(for:))
    if coordinates.count >= 2 {
      MapPolyline(coordinates: coordinates)
        .stroke(DayPalette.color(forDay: day.dayNumber), style: StrokeStyle(lineWidth: 4))
    }
    ForEach(stops) { stop in
      if let coordinate = coordinate(for: stop) {
        Annotation(stop.content.title, coordinate: coordinate, anchor: .bottom) {
          Circle()
            .fill(DayPalette.color(forDay: day.dayNumber))
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        }
      }
    }
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
