import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// Owns Today’s ephemeral weather request and one minute-level clock. The
/// projection remains a pure value supplied by the trip-planning read model.
@MainActor
@Observable
final class TodayModel {
  /// One idea's header thumbnail bytes — the compressed, syncable tier, never the
  /// heavy display BLOB (mirrors `JourneyModel`).
  @Selection struct HeaderThumb {
    let ideaID: Idea.ID
    let thumbnail: Data
  }

  @ObservationIgnored @Dependency(\.weatherClient) private var weatherClient
  @ObservationIgnored @Dependency(\.date) private var date
  @ObservationIgnored @Dependency(\.continuousClock) private var clock

  // Today only needs compact stop imagery. The display BLOBs never ride this
  // query; lookup is performed only for the active trip's resolved stop ideas.
  @ObservationIgnored @FetchAll(
    ImageAsset.where { $0.isHeader.eq(true) }
      .select { HeaderThumb.Columns(ideaID: $0.ideaID, thumbnail: $0.thumbnail) }
  ) var headerThumbs

  private(set) var now: Date
  private(set) var weather: WeatherSummary?
  private(set) var weatherAnchor: WeatherAnchor?

  /// Header thumbnail bytes per idea, for the active stop's leading image.
  var thumbnailByIdea: [Idea.ID: Data] {
    Dictionary(headerThumbs.map { ($0.ideaID, $0.thumbnail) }, uniquingKeysWith: { first, _ in first })
  }

  /// The thumbnail for one idea, if it has a header image.
  func thumbnail(forIdea ideaID: Idea.ID?) -> Data? {
    guard let ideaID else { return nil }
    return thumbnailByIdea[ideaID]
  }

  func thumbnail(for next: TodayProjection.Next) -> Data? {
    guard case let .stop(stop) = next.item else { return nil }
    return thumbnail(forIdea: stop.idea?.id)
  }

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
