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

  /// One region's romance thumbnail plus its Unsplash attribution — the panel's
  /// ambient region image. Thumbnail-only, so a growing region library never
  /// drags display BLOBs into memory (display-on-demand is a later refinement).
  @Selection struct RegionThumb {
    let regionID: MapRegion.ID
    let thumbnail: Data
    let photographerName: String?
    let photographerUsername: String?
  }

  @ObservationIgnored @Dependency(\.weatherClient) private var weatherClient
  @ObservationIgnored @Dependency(\.date) private var date

  // Only header rows' thumbnail bytes load — a disclosure row and the panel show
  // small images; the display BLOBs never ride this query.
  @ObservationIgnored @FetchAll(
    ImageAsset.where { $0.isHeader.eq(true) }
      .select { HeaderThumb.Columns(ideaID: $0.ideaID, thumbnail: $0.thumbnail) }
  ) var headerThumbs

  @ObservationIgnored @FetchAll(
    RegionImage.all.select {
      RegionThumb.Columns(
        regionID: $0.regionID,
        thumbnail: $0.thumbnail,
        photographerName: $0.photographerName,
        photographerUsername: $0.photographerUsername)
    }
  ) var regionThumbs

  // Region rows are light (BLOBs live in the separate `regionImages` table), so
  // the whole set is cheap to hold for geographic resolution.
  @ObservationIgnored @FetchAll(MapRegion.all) var allRegions

  /// Header thumbnail bytes per idea, for stop/hotel imagery across the surface.
  var thumbnailByIdea: [Idea.ID: Data] {
    Dictionary(headerThumbs.map { ($0.ideaID, $0.thumbnail) }, uniquingKeysWith: { first, _ in first })
  }

  /// The thumbnail for one idea, if it has a header image.
  func thumbnail(forIdea ideaID: Idea.ID?) -> Data? {
    guard let ideaID else { return nil }
    return thumbnailByIdea[ideaID]
  }

  private var regionThumbByRegion: [MapRegion.ID: RegionThumb] {
    Dictionary(regionThumbs.map { ($0.regionID, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// A region's romance thumbnail, if it has one.
  func regionThumbnail(forRegion regionID: MapRegion.ID?) -> Data? {
    guard let regionID else { return nil }
    return regionThumbByRegion[regionID]?.thumbnail
  }

  /// A region photo's Unsplash attribution, if the photo carries it (Photos picks
  /// don't). Returns the photographer's display name and optional username.
  func regionAttribution(
    forRegion regionID: MapRegion.ID?
  ) -> (name: String, username: String?)? {
    guard let regionID, let thumb = regionThumbByRegion[regionID],
      let name = thumb.photographerName, !name.isEmpty
    else { return nil }
    return (name, thumb.photographerUsername)
  }

  /// The `MapRegion` geographically covering a coordinate, if any — the panel's
  /// fallback when a day carries no explicit `TripDayRegion` assignment, so a
  /// region photo can attach wherever a saved region covers the place.
  func region(containingLatitude latitude: Double?, longitude longitude: Double?) -> MapRegion? {
    guard let latitude, let longitude else { return nil }
    return allRegions.first { $0.contains(latitude: latitude, longitude: longitude) }
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
