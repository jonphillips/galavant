import Dependencies
import Foundation
import GalavantCapture
import GalavantSchema
import MapKit

/// The resolved location for a captured page: a coordinate, plus everything else
/// the Apple Maps hit knew (name, address, region, kind, phone, link) so the draft
/// can be enriched with it. A scraped-coordinate or geocoded-address match carries
/// only the coordinate — the page's own values stand for the rest.
public struct LocationMatch: Equatable, Sendable {
  public var coordinate: ParsedCoordinate
  public var name: String?
  public var address: String?
  public var regionName: String?
  public var kind: IdeaKind?
  public var phone: String?
  public var url: String?
  /// Apple Maps' persistent place identity (`MKMapItem.identifier.rawValue`), carried
  /// from the matched `Place` so capture can stamp it as the ADR-0019 dedup key. `nil`
  /// for a coordinate-only or geocoded match with no POI identity.
  public var mapItemIdentifier: String?
  public var timeZoneIdentifier: String?

  public init(
    coordinate: ParsedCoordinate,
    name: String? = nil,
    address: String? = nil,
    regionName: String? = nil,
    kind: IdeaKind? = nil,
    phone: String? = nil,
    url: String? = nil,
    mapItemIdentifier: String? = nil,
    timeZoneIdentifier: String? = nil
  ) {
    self.coordinate = coordinate
    self.name = name
    self.address = address
    self.regionName = regionName
    self.kind = kind
    self.phone = phone
    self.url = url
    self.mapItemIdentifier = mapItemIdentifier
    self.timeZoneIdentifier = timeZoneIdentifier
  }
}

/// Executes the pure `PlaceMatching.ladder` against live (injected) geocoding and
/// search, with the auto-widen behavior from scraping-enrichment.md: take the
/// strongest signal the page gave (scraped coordinates win outright), else
/// geocode the address, else text-search and accept the best-scoring hit only
/// when it clears a confidence threshold. MapKit/CoreLocation live **only** behind
/// the two closures, so the orchestration is testable with fixtures.
public struct PlaceMatcher: Sendable {
  var geocode: @Sendable (_ address: String) async -> Place?
  var search: @Sendable (_ query: String) async -> [Place]
  /// The existing region-required Maps search used when a reviewed recommendation
  /// needs human confirmation. It stays separate from the capture ladder's
  /// worldwide fallback because resolution must show choices, never auto-select one.
  var recommendationSearch: @Sendable (_ query: String, _ regions: [MapRegion]) async -> [Place]
  /// Region-biased POI lookup around an already-resolved coordinate — the
  /// enrichment ("supplementer") boundary. Returns Apple Maps records near the
  /// point so we can merge the canonical kind/phone/link onto a match the page
  /// under-described. Defaults to none (no enrichment) for tests/previews.
  var lookupNear: @Sendable (_ query: String, _ coordinate: ParsedCoordinate) async -> [Place]
  /// The civil-time zone at a bare coordinate. Calendar reconciliation uses it to
  /// give an absolute commitment a *principled destination* zone — the trip's
  /// planning region — when the matched venue resolved none. Never the device or
  /// event zone (ADR-0034). Defaults to none for tests/previews.
  var timeZoneLookup: @Sendable (_ latitude: Double, _ longitude: Double) async -> TimeZone?

  public init(
    geocode: @escaping @Sendable (_ address: String) async -> Place?,
    search: @escaping @Sendable (_ query: String) async -> [Place],
    recommendationSearch: @escaping @Sendable (_ query: String, _ regions: [MapRegion]) async -> [Place] = {
      _, _ in []
    },
    lookupNear: @escaping @Sendable (_ query: String, _ coordinate: ParsedCoordinate) async -> [Place] = {
      _, _ in []
    },
    timeZone: @escaping @Sendable (_ latitude: Double, _ longitude: Double) async -> TimeZone? = {
      _, _ in nil
    }
  ) {
    self.geocode = geocode
    self.search = search
    self.recommendationSearch = recommendationSearch
    self.lookupNear = lookupNear
    self.timeZoneLookup = timeZone
  }

  /// The civil-time zone at `latitude`/`longitude`, or nil if it can't be
  /// resolved. Public entry point over the injected `timeZone` boundary.
  public func timeZone(latitude: Double, longitude: Double) async -> TimeZone? {
    await timeZoneLookup(latitude, longitude)
  }

  /// Search a candidate's author-provided Apple-Maps hint in the trip's regions.
  /// The result remains a list for human confirmation; no candidate becomes a place
  /// until `RecommendationResolution.confirm` receives a picked result.
  public func matches(
    for candidate: TripCandidate,
    in regions: [MapRegion]
  ) async -> [Place] {
    guard let query = PlaceMatching.recommendationQuery(
      searchHint: candidate.searchHint,
      locality: candidate.locality,
      fallbackName: candidate.name
    ) else { return [] }
    return await recommendationSearch(query, regions)
  }

  /// Resolve `page` to a location, or `nil` if no signal pans out (the caller
  /// keeps whatever the page already had and lets the user fix it).
  /// `minimumScore` is the word-overlap floor a text-search hit must clear to be
  /// trusted for an unattended capture.
  public func match(_ page: ParsedPage, minimumScore: Int = 1) async -> LocationMatch? {
    guard let base = await resolve(page, minimumScore: minimumScore) else { return nil }
    return await enriched(base, for: page)
  }

  /// Resolve the place named by an external calendar event through the same Maps
  /// ladder as web capture. Calendar reconciliation has no HTML document to parse,
  /// but an event's title, optional structured-location coordinate, and free-form
  /// location carry the equivalent signals. Keeping this adapter here means the M7
  /// spike exercises `PlaceMatcher`, not a second name-matching implementation.
  public func match(
    calendarEventTitle title: String,
    latitude: Double? = nil,
    longitude: Double? = nil,
    location: String? = nil
  ) async -> LocationMatch? {
    let coordinate: ParsedCoordinate? = if let latitude, let longitude {
      ParsedCoordinate(latitude: latitude, longitude: longitude)
    } else {
      nil
    }
    // A calendar event names its venue in `location`; the title is the subject
    // ("Museum Day", "Dinner"), not the place. Resolve from the location when present
    // so an event with a real Maps location adopts that venue's identity and name —
    // otherwise a coordinate-only match self-identifies by the title and a non-venue
    // title gates out the correct POI sitting directly under the pin.
    let placeName = location.flatMap { $0.isEmpty ? nil : $0 } ?? title
    return await match(
      ParsedPage(
        title: placeName,
        coordinate: coordinate,
        address: ParsedAddress(street: location)
      )
    )
  }

  /// Walk the signal ladder to a first location, or nil if nothing pans out.
  private func resolve(_ page: ParsedPage, minimumScore: Int) async -> LocationMatch? {
    var searched: [String: [Place]] = [:]

    for step in PlaceMatching.ladder(for: page) {
      switch step {
      case let .coordinates(latitude, longitude):
        // Scraped coordinates are authoritative — no lookup needed.
        return LocationMatch(coordinate: ParsedCoordinate(latitude: latitude, longitude: longitude))

      case let .geocodeAddress(address):
        // Keep the whole geocoded map item, not just its coordinate — an address
        // that resolves to a known business carries its name/kind/phone/link.
        if let place = await geocode(address) {
          return LocationMatch(place: place)
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
        if let best = bestPlace(in: results, for: page, minimumScore: minimumScore) {
          return LocationMatch(place: best)
        }
      }
    }
    return nil
  }

  /// Supplement a resolved location with the canonical Apple Maps record near it —
  /// filling only the fields the page (and the resolving step) left blank, gated on
  /// a name match so a wrong nearby POI can't hijack the record. Skipped when the
  /// match already carries the enrichable fields, or the page has no name to search.
  ///
  /// Crucially this is the **only** route to a `mapItemIdentifier` (the ADR-0019
  /// dedup key) for a match resolved by scraped coordinates or by geocoding an
  /// address — both yield a point with no POI identity (forward geocoding returns an
  /// address-level map item, not a business). So a hotel whose pin resolves fine via
  /// JSON-LD `geo`/`address` (Forestis, Das Achental) still needs this pass to adopt
  /// the nearby POI's identity, or its capture lands undeduplicatable.
  private func enriched(_ match: LocationMatch, for page: ParsedPage) async -> LocationMatch {
    guard match.kind == nil || match.phone == nil || match.url == nil
      || match.mapItemIdentifier == nil || match.timeZoneIdentifier == nil,
      let name = page.title, !name.isEmpty
    else { return match }
    let candidates = await lookupNear(name, match.coordinate)
    guard let poi = bestPlace(in: candidates, for: page) else { return match }
    var match = match
    if match.name == nil { match.name = poi.name }
    if match.address == nil { match.address = poi.address }
    if match.regionName == nil { match.regionName = poi.regionName }
    if match.kind == nil { match.kind = poi.kind }
    if match.phone == nil { match.phone = poi.phone }
    if match.url == nil { match.url = poi.url }
    // Adopt the POI's persistent identity when the resolving step gave none — a
    // coordinate- or geocode-first match has no dedup key otherwise (ADR-0019).
    if match.mapItemIdentifier == nil { match.mapItemIdentifier = poi.mapItemIdentifier }
    if match.timeZoneIdentifier == nil { match.timeZoneIdentifier = poi.timeZoneIdentifier }
    return match
  }

  /// The highest name+street-overlap candidate clearing `minimumScore`. The scoring
  /// gate zeroes matches without name overlap, so the default floor of 1 means
  /// "the names actually agree."
  private func bestPlace(in results: [Place], for page: ParsedPage, minimumScore: Int = 1) -> Place? {
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
    return best.0
  }
}

extension LocationMatch {
  /// Build a match from an Apple Maps `Place`, carrying its full detail.
  init(place: Place) {
    self.init(
      coordinate: ParsedCoordinate(latitude: place.latitude, longitude: place.longitude),
      name: place.name,
      address: place.address,
      regionName: place.regionName,
      kind: place.kind,
      phone: place.phone,
      url: place.url,
      mapItemIdentifier: place.mapItemIdentifier,
      timeZoneIdentifier: place.timeZoneIdentifier
    )
  }
}

extension PlaceMatcher: DependencyKey {
  public static let liveValue = PlaceMatcher(
    geocode: { address in
      // iOS 26 forward-geocoding (CLGeocoder is deprecated): MKGeocodingRequest
      // exposes `mapItems` as an async getter (NS_SWIFT_ASYNC_NAME, per the SDK
      // header). Keep the whole map item — when the address resolves to a business
      // it carries the POI's name/kind/phone/link, not just a coordinate.
      guard let request = MKGeocodingRequest(addressString: address) else { return nil }
      let mapItems = try? await request.mapItems
      guard let item = mapItems?.first else { return nil }
      return Place(mapItem: item)
    },
    search: { query in
      // Reuse the tuned worldwide natural-language search from PlaceSearchClient.
      (try? await PlaceSearchClient.liveValue.search(query, .worldwide)) ?? []
    },
    recommendationSearch: { query, regions in
      let scope: PlaceSearchScope = regions.isEmpty ? .worldwide : .regions(regions)
      return (try? await PlaceSearchClient.liveValue.search(query, scope)) ?? []
    },
    lookupNear: { query, coordinate in
      // The enrichment pass: a tight, region-biased POI search around the point we
      // already resolved. Because it's anchored to a known location it can't wander
      // to a same-named place in another country (the worldwide search's failure
      // mode); it just fetches Apple Maps' canonical record to fill blanks.
      let request = MKLocalSearch.Request()
      request.naturalLanguageQuery = query
      request.resultTypes = [.pointOfInterest]
      request.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
        latitudinalMeters: 2_000,
        longitudinalMeters: 2_000
      )
      let response = try? await MKLocalSearch(request: request).start()
      return response?.mapItems.prefix(10).map(Place.init(mapItem:)) ?? []
    },
    timeZone: { latitude, longitude in
      // iOS 26 reverse-geocoding (CLGeocoder is deprecated): MKReverseGeocodingRequest
      // exposes `mapItems` as an async getter (NS_SWIFT_ASYNC_NAME, per the SDK header).
      // The nearest map item's `timeZone` is the region's civil zone.
      let location = CLLocation(latitude: latitude, longitude: longitude)
      guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
      let mapItems = try? await request.mapItems
      return mapItems?.first?.timeZone
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
