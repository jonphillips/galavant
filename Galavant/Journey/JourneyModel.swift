import Dependencies
import Foundation
import GalavantSchema
import ImageIO
import SQLiteData
import UIKit

/// Owns Journey's optional, device-local weather enrichment and the header
/// thumbnails the day disclosure and image panel render. The projection stays a
/// pure value; this model coordinates weather and selection-scoped image reads.
@MainActor
@Observable
final class JourneyModel {
  struct WeatherKey: Hashable, Sendable {
    var dayNumber: Int
    var anchorIndex: Int
  }

  enum DisplayImageKey: Hashable, Sendable {
    case idea(Idea.ID)
    case region(MapRegion.ID)
  }

  struct DisplayRequest: Equatable, Sendable {
    var keys: [DisplayImageKey]
  }

  /// One idea's header thumbnail bytes — the compressed, syncable tier, never the
  /// heavy display BLOB (mirrors `IdeasListModel`, M4f).
  @Selection struct HeaderThumb {
    let ideaID: Idea.ID
    let thumbnail: Data
  }

  /// One region's romance thumbnail plus its Unsplash attribution — the panel's
  /// ambient region image. Thumbnail-only; display bytes are loaded on demand.
  @Selection struct RegionThumb {
    let regionID: MapRegion.ID
    let thumbnail: Data
    let photographerName: String?
    let photographerUsername: String?
  }

  @ObservationIgnored @Dependency(\.weatherClient) private var weatherClient
  @ObservationIgnored @Dependency(\.date) private var date
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database

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
  func region(containingLatitude latitude: Double?, longitude: Double?) -> MapRegion? {
    guard let latitude, let longitude else { return nil }
    return allRegions.first { $0.contains(latitude: latitude, longitude: longitude) }
  }

  /// WeatherKit's daily forecast horizon is the reason Journey is intentionally
  /// weather-free for trips farther than ten days from the device date.
  private static let forecastHorizonDays = 10

  private(set) var weather: [WeatherKey: WeatherSummary] = [:]
  private(set) var displayImages: [DisplayImageKey: UIImage] = [:]

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

  func displayImage(forIdea ideaID: Idea.ID?) -> UIImage? {
    guard let ideaID else { return nil }
    return displayImages[.idea(ideaID)]
  }

  func displayImage(forRegion regionID: MapRegion.ID?) -> UIImage? {
    guard let regionID else { return nil }
    return displayImages[.region(regionID)]
  }

  /// Computes exactly the display-tier images the current panel can show. The
  /// request is also the task identity, so a selection or thumbnail refresh
  /// replaces the bounded cache instead of accumulating display BLOBs.
  func displayRequest(
    projection: JourneyProjection,
    plan: TripPlan,
    selection: JourneySelection?
  ) -> DisplayRequest {
    var keys: [DisplayImageKey] = []

    func append(_ key: DisplayImageKey?) {
      guard let key, !keys.contains(key) else { return }
      keys.append(key)
    }

    func appendIdea(_ ideaID: Idea.ID?) {
      guard let ideaID else { return }
      append(.idea(ideaID))
    }

    func appendRegion(_ regionID: MapRegion.ID?) {
      guard let regionID else { return }
      append(.region(regionID))
    }

    switch selection {
    case .day(let dayNumber):
      appendRegion(region(forDay: dayNumber, in: plan)?.id)
      for stop in projection.days.first(where: { $0.dayNumber == dayNumber })?.stops ?? [] {
        if thumbnail(forIdea: stop.ideaID) != nil {
          appendIdea(stop.ideaID)
        }
      }
    case .stay(let stayID):
      guard let band = projection.stayBands.first(where: { $0.id == stayID }) else {
        return DisplayRequest(keys: keys)
      }
      appendRegion(region(forStay: band, in: plan)?.id)
      appendIdea(band.stay.idea?.id)
      if let stop = JourneyImageSelection.stableStayStop(
        stayID: band.id,
        nights: band.nights,
        days: projection.days,
        hasImage: { self.thumbnail(forIdea: $0) != nil }) {
        appendIdea(stop.ideaID)
      }
    case .none:
      appendRegion(projection.days.first.flatMap { region(forDay: $0.dayNumber, in: plan) }?.id)
    }
    return DisplayRequest(keys: keys)
  }

  /// Reads and decodes only the current panel's display-tier images. Database
  /// reads stay one-shot and the ImageIO decode happens in a detached task so
  /// the main actor only receives ready-to-render CGImages.
  func loadDisplayImages(_ request: DisplayRequest) async {
    displayImages = [:]
    guard !request.keys.isEmpty else { return }

    let dataByKey: [DisplayImageKey: Data]
    do {
      dataByKey = try await database.read { db in
        var result: [DisplayImageKey: Data] = [:]
        for key in request.keys {
          switch key {
          case .idea(let ideaID):
            if let display = try ImageAsset.where { columns in
              columns.ideaID.eq(ideaID) && columns.isHeader.eq(true)
            }.fetchOne(db)?.display {
              result[key] = display
            }
          case .region(let regionID):
            if let display = try RegionImage.where({ columns in
              columns.regionID.eq(regionID)
            }).fetchOne(db)?.display {
              result[key] = display
            }
          }
        }
        return result
      }
    } catch {
      return
    }

    guard !Task.isCancelled else { return }
    let decoded = await Task.detached(priority: .userInitiated) {
      dataByKey.compactMap { key, data -> (DisplayImageKey, CGImage)? in
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (key, image)
      }
    }.value
    guard !Task.isCancelled else { return }
    displayImages = Dictionary(uniqueKeysWithValues: decoded.map { ($0.0, UIImage(cgImage: $0.1)) })
  }

  private func region(forDay dayNumber: Int, in plan: TripPlan) -> MapRegion? {
    if let assigned = plan.region(forDay: dayNumber) { return assigned }
    let stop = plan.locatedStops(forDay: dayNumber).first
    return region(containingLatitude: stop?.content.latitude, longitude: stop?.content.longitude)
  }

  private func region(forStay band: JourneyProjection.StayBand, in plan: TripPlan) -> MapRegion? {
    if let assigned = plan.region(forDay: band.nights.lowerBound) { return assigned }
    return region(
      containingLatitude: band.stay.content.latitude, longitude: band.stay.content.longitude)
  }
}
