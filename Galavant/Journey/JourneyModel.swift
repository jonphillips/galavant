import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// Owns Journey's optional, device-local weather enrichment and the header
/// thumbnails the day disclosure and image panel render. The projection stays a
/// pure value; this model coordinates the forecast pass and observes the
/// (thumbnail-only) image rows.
@MainActor
@Observable
final class JourneyModel {
  struct WeatherKey: Hashable, Sendable {
    var dayNumber: Int
    var anchorIndex: Int
  }

  /// One idea's header thumbnail bytes — the compressed, syncable tier, never the
  /// heavy display BLOB (mirrors `IdeasListModel`, M4f).
  @Selection struct HeaderThumb {
    let ideaID: Idea.ID
    let thumbnail: Data
  }

  @ObservationIgnored @Dependency(\.weatherClient) private var weatherClient
  @ObservationIgnored @Dependency(\.date) private var date

  // Only header rows' thumbnail bytes load — a disclosure row and the panel show
  // small images; the display BLOBs never ride this query.
  @ObservationIgnored @FetchAll(
    ImageAsset.where { $0.isHeader.eq(true) }
      .select { HeaderThumb.Columns(ideaID: $0.ideaID, thumbnail: $0.thumbnail) }
  ) var headerThumbs

  /// Header thumbnail bytes per idea, for stop/hotel imagery across the surface.
  var thumbnailByIdea: [Idea.ID: Data] {
    Dictionary(headerThumbs.map { ($0.ideaID, $0.thumbnail) }, uniquingKeysWith: { first, _ in first })
  }

  /// The thumbnail for one idea, if it has a header image.
  func thumbnail(forIdea ideaID: Idea.ID?) -> Data? {
    guard let ideaID else { return nil }
    return thumbnailByIdea[ideaID]
  }

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
