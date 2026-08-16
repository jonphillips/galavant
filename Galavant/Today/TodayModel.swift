import Dependencies
import Foundation
import GalavantSchema

/// Owns Today’s ephemeral weather request and one minute-level clock. The
/// projection remains a pure value supplied by the trip-planning read model.
@MainActor
@Observable
final class TodayModel {
  @ObservationIgnored @Dependency(\.weatherClient) private var weatherClient
  @ObservationIgnored @Dependency(\.date) private var date
  @ObservationIgnored @Dependency(\.continuousClock) private var clock

  private(set) var now: Date
  private(set) var weather: WeatherSummary?
  private(set) var weatherAnchor: WeatherAnchor?

  init() {
    @Dependency(\.date) var date
    now = date()
  }

  /// One scoped clock task refreshes the projection at minute boundaries. ETA
  /// freshness remains owned by the planning model; this deliberately avoids a
  /// second Directions polling loop before Slice 4 establishes that policy.
  func runClock() async {
    while !Task.isCancelled {
      now = date()
      let interval = secondsUntilNextMinute(after: now)
      do {
        try await clock.sleep(for: .seconds(interval))
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }
  }

  /// Requests exactly the granularity resolved by the functional core. A new
  /// anchor replaces the displayed value; the WeatherKit client owns expiry.
  func loadWeather(for anchor: WeatherAnchor?) async {
    guard anchor != weatherAnchor else { return }
    weatherAnchor = anchor
    weather = nil
    guard let anchor else { return }

    do {
      let summary = try await weatherClient.forecast(
        anchor.coordinate,
        anchor.timeWindow,
        anchor.weatherGranularity)
      guard !Task.isCancelled, weatherAnchor == anchor else { return }
      weather = summary
    } catch is CancellationError {
      return
    } catch {
      // Weather is optional enrichment. The designed no-weather state remains
      // complete when WeatherKit is unavailable or outside its forecast horizon.
      guard weatherAnchor == anchor else { return }
      weather = nil
    }
  }

  private func secondsUntilNextMinute(after date: Date) -> Double {
    let remainder = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60)
    return Swift.max(1, 60 - remainder)
  }
}
