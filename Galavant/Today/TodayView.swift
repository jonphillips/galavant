import Foundation
import GalavantSchema
import MapKit
import SwiftUI
import UIKit

enum TodayDirectionsEmphasis {
  case prominent
  case bordered
  case quiet
}

struct TodayDirectionsButtonStyle: ViewModifier {
  let emphasis: TodayDirectionsEmphasis

  @ViewBuilder
  func body(content: Content) -> some View {
    switch emphasis {
    case .prominent:
      content.buttonStyle(.borderedProminent)
    case .bordered:
      content.buttonStyle(.bordered)
    case .quiet:
      content.buttonStyle(.borderless)
    }
  }
}

/// The on-the-ground iPhone projection of one dated trip. This deliberately
/// receives the existing planning model rather than owning persistence or a
/// competing itinerary model.
struct TodayView: View {
  let planningModel: TripPlanningModel

  @Environment(\.dismiss) private var dismiss
  @State private var model = TodayModel()
  /// The day the user has stepped to. `nil` means "follow the live day".
  @State private var selectedDay: Int?
  @State private var detailIdea: Idea?

  private static let leaveByBuffer: TimeInterval = 10 * 60

  private var tripStartDate: Date? { planningModel.trip?.startDate }
  private var dayCount: Int { planningModel.plan.lengthInDays }

  /// The trip day the real clock is on, or `nil` when the trip isn't underway.
  private var liveDay: Int? {
    guard let tripStartDate else { return nil }
    return TodayProjection.tripDay(
      containing: model.now, tripStartDate: tripStartDate, in: planningModel.plan)
  }

  /// The day currently shown: an explicit selection, else the live day, else day 1.
  private var currentDay: Int? {
    selectedDay ?? liveDay ?? (dayCount >= 1 ? 1 : nil)
  }

  /// We are previewing whenever the shown day isn't the live day (including any day
  /// at all when the trip isn't underway).
  private var isPreviewing: Bool {
    guard let currentDay else { return false }
    return currentDay != liveDay
  }

  /// The instant to render: the live clock when live, otherwise the start of the
  /// previewed day (Jon's decision — a morning-of view of the whole day).
  private var renderNow: Date {
    guard isPreviewing, let currentDay, let tripStartDate,
      let start = TodayProjection.startOfTripDay(currentDay, tripStartDate: tripStartDate)
    else { return model.now }
    return start
  }

  /// The projection is rendered at the start of a previewed day, so its next
  /// anchor is that day's forecast. WeatherKit bounds the request naturally.
  private var activeWeatherAnchor: WeatherAnchor? {
    projection?.next?.weatherAnchor
  }

  private var showsDayStepper: Bool { tripStartDate != nil && dayCount >= 1 }

  private func step(_ delta: Int) {
    let current = currentDay ?? 1
    selectedDay = min(max(1, current + delta), dayCount)
  }

  private var projection: TodayProjection? {
    guard let tripStartDate else { return nil }
    return TodayProjection.resolve(
      from: planningModel.plan,
      now: renderNow,
      tripStartDate: tripStartDate,
      travelTimes: planningModel.travelTimes,
      effectiveModes: planningModel.effectiveModes,
      leaveByBuffer: Self.leaveByBuffer)
  }

  /// `TodayProjection.Next` intentionally stays focused on the render model.
  /// The existing itinerary stream still owns the connector needed for the one
  /// shared Apple Maps handoff.
  private var nextConnector: TravelConnector? {
    guard
      let projection,
      let tripStartDate = planningModel.trip?.startDate,
      let nextID = projection.next?.item.id
    else { return nil }
    return planningModel.plan.itineraryItems(
      forDay: projection.dayContext.dayNumber,
      travelTimes: planningModel.travelTimes,
      effectiveModes: planningModel.effectiveModes,
      now: renderNow,
      tripStartDate: tripStartDate,
      stays: planningModel.plan.stays(coveringDay: projection.dayContext.dayNumber))
      .compactMap { item -> TravelConnector? in
        guard case let .connector(connector) = item, connector.to.id == nextID else { return nil }
        return connector
      }
      .first
  }

  private var nextIdeaID: Idea.ID? {
    guard let next = projection?.next, case let .stop(stop) = next.item else { return nil }
    return stop.idea?.id
  }

  private var displayImageIdeaIDs: [Idea.ID] {
    var ideaIDs: [Idea.ID] = []
    if let nextIdeaID { ideaIDs.append(nextIdeaID) }
    if let detailIdea, !ideaIDs.contains(detailIdea.id) {
      ideaIDs.append(detailIdea.id)
    }
    return ideaIDs
  }

  var body: some View {
    NavigationStack {
      Group {
        if let projection {
          today(projection)
        } else if tripStartDate == nil {
          ContentUnavailableView(
            "Today is not available",
            systemImage: "calendar.badge.clock",
            description: Text("Set this trip’s start date before using its Today view."))
        } else {
          ContentUnavailableView(
            "No days planned yet",
            systemImage: "calendar.badge.clock",
            description: Text("Add itinerary days to preview this trip’s Today view."))
        }
      }
      .navigationTitle("Today")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
        if showsDayStepper {
          ToolbarItemGroup(placement: .bottomBar) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
              .disabled((currentDay ?? 1) <= 1)
            Spacer()
            HStack(spacing: 8) {
              Text("Day \(currentDay ?? 1) of \(dayCount)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
              if isPreviewing {
                Text("PREVIEW")
                  .font(.caption2.weight(.bold))
                  .tracking(0.5)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(.tint.opacity(0.15), in: Capsule())
                  .foregroundStyle(.tint)
              }
            }
            Spacer()
            Button { step(+1) } label: { Image(systemName: "chevron.right") }
              .disabled((currentDay ?? 1) >= dayCount)
          }
        }
      }
    }
    .task { await model.runClock() }
    .task(id: activeWeatherAnchor) {
      await model.loadWeather(for: activeWeatherAnchor)
    }
    .task(id: displayImageIdeaIDs) {
      await model.loadDisplayImages(displayImageIdeaIDs)
    }
    .sheet(item: $detailIdea) { idea in
      NavigationStack {
        IdeaDetailView(
          idea: idea,
          tagNames: planningModel.tagNames(for: idea),
          interests: planningModel.interests(for: idea),
          evaluations: planningModel.evaluations(for: idea),
          stopContext: planningModel.stopContext(for: idea),
          headerImage: model.displayImageData(forIdea: idea.id)
            ?? model.thumbnail(forIdea: idea.id))
          .navigationTitle(idea.name)
          .navigationBarTitleDisplayMode(.inline)
      }
    }
  }

  private func today(_ projection: TodayProjection) -> some View {
    let thumbnailByIdea = model.thumbnailByIdea

    return ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        TodayDayHeader(
          context: projection.dayContext,
          progress: projection.progress,
          canExecute: !isPreviewing,
          weather: model.weather)

        if let next = projection.next {
          TodayNextHero(
            next: next,
            connector: nextConnector,
            canExecute: !isPreviewing,
            planningModel: planningModel,
            onSelectIdea: { detailIdea = $0 },
            weather: model.weather,
            thumbnailByIdea: thumbnailByIdea,
            displayImage: model.displayImage(forIdea: nextIdeaID))
        } else {
          TodayNoNextCard()
        }

        let timeline = isPreviewing
          ? projection.remaining.filter {
              if case .item(.nowMarker) = $0 { return false }
              return true
            }
          : projection.remaining
        if !timeline.isEmpty {
          TodayTimeline(
            remaining: timeline,
            doneStops: projection.doneStops,
            skippedStops: projection.skippedStops,
            canExecute: !isPreviewing,
            planningModel: planningModel,
            onSelectIdea: { detailIdea = $0 },
            thumbnailByIdea: thumbnailByIdea)
        }

        if let tonight = projection.tonight {
          TodayTonightCard(tonight: tonight)
        }

        if let tomorrow = projection.tomorrow {
          TodayTomorrowCard(tomorrow: tomorrow)
        }
      }
      .padding(20)
    }
    .background(Color(.systemGroupedBackground))
  }
}

private struct TodayDayHeader: View {
  let context: TodayProjection.DayContext
  let progress: TodayProjection.Progress
  let canExecute: Bool
  let weather: WeatherSummary?
  @State private var isShowingWeatherDetail = false

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
          .font(.title2.weight(.bold))
        HStack(spacing: 6) {
          Text("Day \(context.dayNumber)")
          if canExecute, progress.total > 0 {
            Text("\(progress.done) of \(progress.total)")
              .accessibilityLabel("\(progress.done) of \(progress.total) stops complete")
          }
          if let locality = context.locality {
            Text("•")
            Text(locality)
          }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      if let weather {
        VStack(alignment: .trailing, spacing: 5) {
          if !canExecute, weather.current == nil, let daily = weather.daily {
            Button {
              isShowingWeatherDetail = true
            } label: {
              HStack(spacing: 8) {
                Image(systemName: daily.symbolName)
                  .font(.title2)
                  .symbolRenderingMode(.hierarchical)
                Text("\(temperature(daily.highTemperature)) / \(temperature(daily.lowTemperature))")
                  .font(.title3.weight(.bold))
                  .monospacedDigit()
              }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(
              "Daily weather forecast, \(daily.condition), high \(temperature(daily.highTemperature)), low \(temperature(daily.lowTemperature))")
            .accessibilityHint("Shows weather details.")
          } else if let reading = TodayWeatherReading.ambient(in: weather) {
            Button {
              isShowingWeatherDetail = true
            } label: {
              HStack(spacing: 5) {
                Image(systemName: reading.symbolName)
                  .symbolRenderingMode(.hierarchical)
                Text(reading.temperature)
                  .font(.subheadline.weight(.semibold))
              }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Current weather, \(reading.condition), \(reading.temperature)")
            .accessibilityHint("Shows weather details.")
          }

          WeatherAttributionLink(attribution: weather.attribution)
            .frame(width: 88, height: 14, alignment: .trailing)
        }
        .sheet(isPresented: $isShowingWeatherDetail) {
          WeatherDetailView(summary: weather)
            .presentationDetents([.medium])
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Today, day \(context.dayNumber)\(context.locality.map { ", \($0)" } ?? "")")
  }

  private func temperature(_ measurement: Measurement<UnitTemperature>) -> String {
    measurement.formatted(
      .measurement(
        width: .narrow,
        usage: .weather,
        numberFormatStyle: .number.precision(.fractionLength(0))))
  }
}

private struct TodayNextHero: View {
  let next: TodayProjection.Next
  let connector: TravelConnector?
  let canExecute: Bool
  let planningModel: TripPlanningModel
  let onSelectIdea: (Idea) -> Void
  let weather: WeatherSummary?
  let thumbnailByIdea: [Idea.ID: Data]
  let displayImage: UIImage?

  private var stop: ResolvedStop? {
    guard case let .stop(stop) = next.item else { return nil }
    return stop
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("NEXT")
        .font(.caption.weight(.bold))
        .foregroundStyle(.tint)
        .tracking(1.2)

      if let stop {
        if let idea = stop.idea {
          Button { onSelectIdea(idea) } label: {
            stopSummary(stop)
          }
          .buttonStyle(.plain)
          .contentShape(Rectangle())
          .accessibilityHint("Shows stop details.")
        } else {
          stopSummary(stop)
        }
      }

      HStack(spacing: 12) {
        if canExecute, let stop {
          Button {
            Task { await planningModel.completeStop(stop.id) }
          } label: {
            Label("Done", systemImage: "checkmark.circle.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
        }

        if let connector {
          directionsButton(for: connector)
        } else if let endpoint = nextEndpoint {
          currentLocationDirectionsButton(to: endpoint)
        }
      }

      if next.weatherAnchor?.isWeatherSensitive == true, let weather {
        TodayDestinationForecast(weather: weather)
      }
    }
    .padding(20)
    .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(.tint.opacity(0.18), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
  }

  private func stopSummary(_ stop: ResolvedStop) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      if let ideaID = stop.idea?.id,
        let image = displayImage ?? thumbnailByIdea[ideaID].flatMap({ UIImage(data: $0) }) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(maxWidth: .infinity)
          .frame(height: 180)
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .accessibilityHidden(true)
      } else if let coordinate = trailCoordinate(for: stop) {
        TodayTrailThumbnail(coordinate: coordinate, title: stop.content.title)
          .frame(maxWidth: .infinity)
          .frame(height: 180)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text(stop.content.title)
          .font(.title.weight(.bold))
          .fixedSize(horizontal: false, vertical: true)

        Text(stop.entry.schedule.display)
          .font(.headline)
          .foregroundStyle(.secondary)

        if let leaveBy = next.leaveBy {
          Label(leaveBy.text, systemImage: connector?.mode.systemImageName ?? "figure.walk.motion")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
        }
      }
    }
  }

  private func directionsButton(for connector: TravelConnector) -> some View {
    Button {
      openInMaps(connector: connector)
    } label: {
      Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
        .frame(width: 36, height: 36)
    }
    .modifier(TodayDirectionsButtonStyle(
      emphasis: canExecute ? .bordered : .prominent))
    .accessibilityLabel("Directions")
    .accessibilityHint("Opens directions from the previous location in Apple Maps.")
  }

  private func currentLocationDirectionsButton(to endpoint: TravelEndpoint) -> some View {
    Button {
      openInMaps(fromCurrentLocationTo: endpoint, mode: planningModel.trip?.mainTransportationMode ?? .walking)
    } label: {
      Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
        .frame(width: 36, height: 36)
    }
    .modifier(TodayDirectionsButtonStyle(
      emphasis: canExecute ? .bordered : .prominent))
    .accessibilityLabel("Directions")
    .accessibilityHint("Opens directions from your current location in Apple Maps.")
  }

  private var nextEndpoint: TravelEndpoint? {
    guard
      let stop,
      let latitude = stop.content.latitude,
      let longitude = stop.content.longitude
    else { return nil }
    return TravelEndpoint(
      id: "stop-\(stop.id)",
      title: stop.content.title,
      latitude: latitude,
      longitude: longitude)
  }

  private func trailCoordinate(for stop: ResolvedStop) -> CLLocationCoordinate2D? {
    guard
      stop.idea?.kind == .outdoorTrail,
      let latitude = stop.content.latitude,
      let longitude = stop.content.longitude
    else { return nil }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}

private struct TodayDestinationForecast: View {
  let weather: WeatherSummary
  @State private var isShowingWeatherDetail = false

  private var reading: TodayWeatherReading? {
    TodayWeatherReading.destination(in: weather)
  }

  var body: some View {
    if let reading {
      Button {
        isShowingWeatherDetail = true
      } label: {
        HStack(spacing: 12) {
          Image(systemName: reading.symbolName)
            .font(.title2)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text("DESTINATION FORECAST")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.secondary)
            Text("\(reading.condition.capitalized) · \(reading.temperature)")
              .font(.subheadline.weight(.semibold))
          }
          Spacer(minLength: 0)
          if let precip = reading.precipitationChance, precip > 0 {
            Text(precip.formatted(.percent.precision(.fractionLength(0))))
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .accessibilityLabel("\(precip.formatted(.percent.precision(.fractionLength(0)))) chance of precipitation")
          }
        }
      }
      .buttonStyle(.plain)
      .padding(14)
      .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Destination forecast, \(reading.condition), \(reading.temperature)")
      .accessibilityHint("Shows weather details.")
      .sheet(isPresented: $isShowingWeatherDetail) {
        WeatherDetailView(summary: weather)
          .presentationDetents([.medium])
      }
    }
  }
}

private struct TodayTrailThumbnail: View {
  let coordinate: CLLocationCoordinate2D
  let title: String

  private var region: MKCoordinateRegion {
    MKCoordinateRegion(
      center: coordinate,
      span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025))
  }

  var body: some View {
    Map(initialPosition: .region(region)) {
      Marker(title, coordinate: coordinate)
    }
    .mapControlVisibility(.hidden)
    .allowsHitTesting(false)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityHidden(true)
  }
}

private struct TodayNoNextCard: View {
  var body: some View {
    ContentUnavailableView(
      "Nothing else is scheduled",
      systemImage: "checkmark.circle",
      description: Text("Your day is clear from here."))
      .frame(maxWidth: .infinity)
      .padding(.vertical, 28)
      .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
  }
}
