import Foundation
import GalavantSchema
import MapKit
import SwiftUI
import UIKit

struct TodayDayHeader: View {
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

      if let weather, let reading = TodayWeatherReading.ambient(in: weather) {
        VStack(alignment: .trailing, spacing: 5) {
          weatherButton(
            reading: reading,
            isDailyPreview: !canExecute && weather.current == nil && weather.daily != nil)

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

  private func weatherButton(reading: TodayWeatherReading, isDailyPreview: Bool) -> some View {
    Button {
      isShowingWeatherDetail = true
    } label: {
      HStack(spacing: isDailyPreview ? 8 : 5) {
        Image(systemName: reading.symbolName)
          .font(isDailyPreview ? .title2 : .body)
          .symbolRenderingMode(.hierarchical)
        Text(reading.temperature)
          .font(
            isDailyPreview
              ? .title3.weight(.bold)
              : .subheadline.weight(.semibold))
      }
    }
    .buttonStyle(.plain)
    .foregroundStyle(isDailyPreview ? .primary : .secondary)
    .accessibilityLabel(
      isDailyPreview
        ? "Daily weather forecast, \(reading.condition), \(reading.temperature)"
        : "Current weather, \(reading.condition), \(reading.temperature)")
    .accessibilityHint("Shows weather details.")
  }
}

struct TodayNextHero: View {
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

struct TodayDestinationForecast: View {
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

struct TodayTrailThumbnail: View {
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

struct TodayNoNextCard: View {
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
