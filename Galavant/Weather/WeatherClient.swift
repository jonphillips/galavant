import CoreLocation
import Dependencies
import Foundation
import GalavantSchema
import WeatherKit

/// Injectable WeatherKit boundary. It answers an already-resolved weather
/// question; `WeatherAnchor` remains the pure owner of where and when to ask.
struct WeatherClient: Sendable {
  var forecast: @Sendable (
    _ coordinate: WeatherAnchor.Coordinate,
    _ window: WeatherAnchor.TimeWindow,
    _ granularity: WeatherAnchor.Granularity
  ) async throws -> WeatherSummary
}

/// The compact, app-owned weather value rendered by Today. It intentionally
/// exposes no WeatherKit types, so views and previews stay framework-free.
struct WeatherSummary: Equatable, Sendable {
  struct Current: Equatable, Sendable {
    var date: Date
    var condition: String
    var symbolName: String
    var temperature: Measurement<UnitTemperature>
    var apparentTemperature: Measurement<UnitTemperature>
  }

  struct Daily: Equatable, Sendable {
    var date: Date
    var condition: String
    var symbolName: String
    var highTemperature: Measurement<UnitTemperature>
    var lowTemperature: Measurement<UnitTemperature>
    var precipitationChance: Double
  }

  struct Hourly: Equatable, Sendable {
    var date: Date
    var condition: String
    var symbolName: String
    var temperature: Measurement<UnitTemperature>
    var precipitationChance: Double
  }

  struct Alert: Equatable, Sendable {
    var summary: String
    var severity: String
    var detailsURL: URL
  }

  /// WeatherKit supplies these at request time. Its legal page is the required
  /// destination for the Apple Weather attribution affordance.
  struct Attribution: Equatable, Sendable {
    var serviceName: String
    var legalPageURL: URL
    var combinedMarkLightURL: URL
    var combinedMarkDarkURL: URL
  }

  var current: Current?
  var daily: Daily?
  var hourlyInterval: [Hourly]
  var alert: Alert?
  var expiration: Date
  var attribution: Attribution

  /// Deterministic offline value for previews and dependency tests.
  static let canned = WeatherSummary(
    current: Current(
      date: .distantPast,
      condition: "clear",
      symbolName: "sun.max.fill",
      temperature: Measurement(value: 21, unit: .celsius),
      apparentTemperature: Measurement(value: 21, unit: .celsius)),
    daily: Daily(
      date: .distantPast,
      condition: "clear",
      symbolName: "sun.max.fill",
      highTemperature: Measurement(value: 24, unit: .celsius),
      lowTemperature: Measurement(value: 14, unit: .celsius),
      precipitationChance: 0.05),
    hourlyInterval: [
      Hourly(
        date: .distantPast,
        condition: "clear",
        symbolName: "sun.max.fill",
        temperature: Measurement(value: 21, unit: .celsius),
        precipitationChance: 0.05)
    ],
    alert: nil,
    expiration: .distantFuture,
    attribution: Attribution(
      serviceName: "Apple Weather",
      legalPageURL: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!,
      combinedMarkLightURL: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!,
      combinedMarkDarkURL: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!))
}

extension WeatherClient: DependencyKey {
  static var liveValue: WeatherClient {
    let cache = WeatherCache()
    let service = WeatherService.shared

    return WeatherClient { coordinate, window, granularity in
      let request = WeatherAnchor.CacheKey(
        coordinate: coordinate,
        window: window,
        granularity: granularity)
      if let cached = await cache.summary(for: request, now: .now) {
        return cached
      }

      let summary = try await fetchWeather(
        service: service,
        coordinate: coordinate,
        window: window,
        granularity: granularity)
      await cache.insert(summary, for: request)
      return summary
    }
  }

  static var previewValue: WeatherClient { .constant(.canned) }
  static var testValue: WeatherClient { .constant(.canned) }
}

extension DependencyValues {
  var weatherClient: WeatherClient {
    get { self[WeatherClient.self] }
    set { self[WeatherClient.self] = newValue }
  }
}

private extension WeatherClient {
  static func constant(_ summary: WeatherSummary) -> Self {
    Self { _, _, _ in summary }
  }
}

private func fetchWeather(
  service: WeatherService,
  coordinate: WeatherAnchor.Coordinate,
  window: WeatherAnchor.TimeWindow,
  granularity: WeatherAnchor.Granularity
) async throws -> WeatherSummary {
  let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
  async let weatherAttribution = service.attribution

  switch granularity {
  case .current:
    let (current, alerts) = try await service.weather(for: location, including: .current, .alerts)
    return WeatherSummary(
      current: current.summary,
      daily: nil,
      hourlyInterval: [],
      alert: alerts?.first?.weatherSummary,
      expiration: expiration(current.metadata, alerts: alerts),
      attribution: try await weatherAttribution.summary)

  case .daily:
    let (daily, alerts) = try await service.weather(for: location, including: .daily, .alerts)
    return WeatherSummary(
      current: nil,
      daily: window.nearestDailyForecastIndex(in: daily.map(\.date)).map { daily[$0].summary },
      hourlyInterval: [],
      alert: alerts?.first?.weatherSummary,
      expiration: expiration(daily.metadata, alerts: alerts),
      attribution: try await weatherAttribution.summary)

  case .hourlyInterval:
    let interval = window.hourlyInterval()
    let (hourly, alerts) = try await service.weather(
      for: location,
      including: .hourly(startDate: interval.start, endDate: interval.end),
      .alerts)
    return WeatherSummary(
      current: nil,
      daily: nil,
      hourlyInterval: hourly.map(\.summary),
      alert: alerts?.first?.weatherSummary,
      expiration: expiration(hourly.metadata, alerts: alerts),
      attribution: try await weatherAttribution.summary)
  }
}

private actor WeatherCache {
  // This intentionally stores fulfilled values only. Today’s single refresh
  // source will own any future in-flight coalescing across anchors.
  private var summaries: [WeatherAnchor.CacheKey: WeatherSummary] = [:]

  func summary(for request: WeatherAnchor.CacheKey, now: Date) -> WeatherSummary? {
    guard let summary = summaries[request] else { return nil }
    guard summary.expiration > now else {
      summaries[request] = nil
      return nil
    }
    return summary
  }

  func insert(_ summary: WeatherSummary, for request: WeatherAnchor.CacheKey) {
    summaries[request] = summary
  }
}

private func expiration(_ metadata: WeatherMetadata, alerts: [WeatherAlert]?) -> Date {
  let dates = [metadata.expirationDate] + (alerts?.map(\.metadata.expirationDate) ?? [])
  return WeatherExpiration.earliest(in: dates) ?? metadata.expirationDate
}

private extension CurrentWeather {
  var summary: WeatherSummary.Current {
    WeatherSummary.Current(
      date: date,
      condition: condition.rawValue,
      symbolName: symbolName,
      temperature: temperature,
      apparentTemperature: apparentTemperature)
  }
}

private extension DayWeather {
  var summary: WeatherSummary.Daily {
    WeatherSummary.Daily(
      date: date,
      condition: condition.rawValue,
      symbolName: symbolName,
      highTemperature: highTemperature,
      lowTemperature: lowTemperature,
      precipitationChance: precipitationChance)
  }
}

private extension HourWeather {
  var summary: WeatherSummary.Hourly {
    WeatherSummary.Hourly(
      date: date,
      condition: condition.rawValue,
      symbolName: symbolName,
      temperature: temperature,
      precipitationChance: precipitationChance)
  }
}

private extension WeatherAlert {
  var weatherSummary: WeatherSummary.Alert {
    WeatherSummary.Alert(summary: summary, severity: severity.rawValue, detailsURL: detailsURL)
  }
}

private extension WeatherAttribution {
  var summary: WeatherSummary.Attribution {
    WeatherSummary.Attribution(
      serviceName: serviceName,
      legalPageURL: legalPageURL,
      combinedMarkLightURL: combinedMarkLightURL,
      combinedMarkDarkURL: combinedMarkDarkURL)
  }
}
