import Dependencies
import Foundation
import GalavantCapture
import MapKit

/// The resolved location for a captured page: a coordinate, plus the canonical
/// name/address when it came from an Apple Maps hit (a scraped-coordinate match
/// carries neither — the page's own values stand).
public struct LocationMatch: Equatable, Sendable {
  public var coordinate: ParsedCoordinate
  public var name: String?
  public var address: String?

  public init(coordinate: ParsedCoordinate, name: String? = nil, address: String? = nil) {
    self.coordinate = coordinate
    self.name = name
    self.address = address
  }
}

/// Executes the pure `PlaceMatching.ladder` against live (injected) geocoding and
/// search, with the auto-widen behavior from scraping-enrichment.md: take the
/// strongest signal the page gave (scraped coordinates win outright), else
/// geocode the address, else text-search and accept the best-scoring hit only
/// when it clears a confidence threshold. MapKit/CoreLocation live **only** behind
/// the two closures, so the orchestration is testable with fixtures.
public struct PlaceMatcher: Sendable {
  var geocode: @Sendable (_ address: String) async -> ParsedCoordinate?
  var search: @Sendable (_ query: String) async -> [Place]

  public init(
    geocode: @escaping @Sendable (_ address: String) async -> ParsedCoordinate?,
    search: @escaping @Sendable (_ query: String) async -> [Place]
  ) {
    self.geocode = geocode
    self.search = search
  }

  /// Resolve `page` to a location, or `nil` if no signal pans out (the caller
  /// keeps whatever the page already had and lets the user fix it).
  /// `minimumScore` is the word-overlap floor a text-search hit must clear to be
  /// trusted for an unattended capture.
  public func match(_ page: ParsedPage, minimumScore: Int = 1) async -> LocationMatch? {
    var searched: [String: [Place]] = [:]

    for step in PlaceMatching.ladder(for: page) {
      switch step {
      case let .coordinates(latitude, longitude):
        // Scraped coordinates are authoritative — no lookup needed.
        return LocationMatch(coordinate: ParsedCoordinate(latitude: latitude, longitude: longitude))

      case let .geocodeAddress(address):
        if let coordinate = await geocode(address) {
          return LocationMatch(coordinate: coordinate)
        }

      case let .biasedTextSearch(query), let .worldwideTextSearch(query):
        // Without a region bias the two text steps are the same search; run each
        // distinct query once.
        let results: [Place]
        if let cached = searched[query] {
          results = cached
        } else {
          results = await search(query)
          searched[query] = results
        }
        if let match = bestMatch(in: results, for: page, minimumScore: minimumScore) {
          return match
        }
      }
    }
    return nil
  }

  private func bestMatch(
    in results: [Place],
    for page: ParsedPage,
    minimumScore: Int
  ) -> LocationMatch? {
    let scrapedName = page.title ?? ""
    let scrapedStreet = page.address.oneLine
    let scored = results.map { place in
      (
        place,
        PlaceMatching.score(
          candidateName: place.name,
          candidateStreet: place.address ?? "",
          scrapedName: scrapedName,
          scrapedStreet: scrapedStreet
        )
      )
    }
    guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= minimumScore else {
      return nil
    }
    return LocationMatch(
      coordinate: ParsedCoordinate(latitude: best.0.latitude, longitude: best.0.longitude),
      name: best.0.name,
      address: best.0.address
    )
  }
}

extension PlaceMatcher: DependencyKey {
  public static let liveValue = PlaceMatcher(
    geocode: { address in
      // iOS 26 forward-geocoding (CLGeocoder is deprecated): MKGeocodingRequest
      // exposes `mapItems` as an async getter (NS_SWIFT_ASYNC_NAME, per the SDK
      // header). World region — capture isn't tied to a map viewport.
      guard let request = MKGeocodingRequest(addressString: address) else { return nil }
      let mapItems = try? await request.mapItems
      guard let coordinate = mapItems?.first?.location.coordinate else { return nil }
      return ParsedCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
    },
    search: { query in
      // Reuse the tuned worldwide natural-language search from PlaceSearchClient.
      (try? await PlaceSearchClient.liveValue.search(query)) ?? []
    }
  )

  /// No network in tests/previews — override per case with fixtures.
  public static let testValue = PlaceMatcher(geocode: { _ in nil }, search: { _ in [] })
}

extension DependencyValues {
  public var placeMatcher: PlaceMatcher {
    get { self[PlaceMatcher.self] }
    set { self[PlaceMatcher.self] = newValue }
  }
}
