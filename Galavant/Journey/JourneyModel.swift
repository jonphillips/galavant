import Dependencies
import Foundation
import GalavantSchema

/// Owns Journey's optional, device-local weather enrichment. The projection
/// stays a pure value; this model only coordinates one forecast pass for the
/// visible day anchors.
@MainActor
@Observable
final class JourneyModel {
  struct WeatherKey: Hashable, Sendable {
    var dayNumber: Int
    var anchorIndex: Int
  }

  @ObservationIgnored @Dependency(\.weatherClient) private var weatherClient
  @ObservationIgnored @Dependency(\.date) private var date

  /// WeatherKit's daily forecast horizon is the reason Journey is intentionally
  /// weather-free for trips farther than ten days from the device date.
  private static let forecastHorizonDays = 10

  private(set) var weather: [WeatherKey: WeatherSummary] = [:]

  var attribution: WeatherSummary.Attribution? {
    weather.values.first?.attribution
  }

  func loadWeather(for projection: JourneyProjection?) async {
    weather = [:]
    guard let projection else { return }

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: date())
    let horizon = calendar.date(
      byAdding: .day,
      value: Self.forecastHorizonDays,
      to: today) ?? today

    for day in projection.days where day.date >= today && day.date <= horizon {
      for (index, anchor) in day.weatherAnchors.enumerated() {
        do {
          let summary = try await weatherClient.forecast(
            anchor.coordinate,
            anchor.timeWindow,
            anchor.weatherGranularity)
          guard !Task.isCancelled else { return }
          weather[WeatherKey(dayNumber: day.dayNumber, anchorIndex: index)] = summary
        } catch is CancellationError {
          return
        } catch {
          // Weather is optional enrichment; the completed weather-free card is
          // still the intended result when WeatherKit is unavailable.
        }
      }
    }
  }

  func summary(for dayNumber: Int, anchorIndex: Int) -> WeatherSummary? {
    weather[WeatherKey(dayNumber: dayNumber, anchorIndex: anchorIndex)]
  }
}
