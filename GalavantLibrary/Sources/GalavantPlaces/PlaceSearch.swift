import Dependencies
import Foundation
import GalavantSchema
import MapKit
import SQLiteData

/// A place we found by searching — the search hit *and* everything MapKit knows
/// about it (kind, link, address, phone), so picking one fully populates an idea.
/// Search-first capture: MapKit is itself a rich enrichment source, so the form
/// becomes confirm-and-tweak rather than blank-fill. (docs/BACKLOG.md)
public struct Place: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var latitude: Double
  public var longitude: Double
  public var regionName: String?
  public var kind: IdeaKind?
  public var url: String?
  public var phone: String?
  public var address: String?
  /// Apple Maps' persistent place identity (`MKMapItem.identifier.rawValue`), carried
  /// so a captured idea can store it as the ADR-0019 dedup key. `nil` for a
  /// geocoded-address or scraped-coordinate result MapKit gave no POI identity to.
  public var mapItemIdentifier: String?
  /// The place's civil-time zone from MapKit. Calendar reconciliation uses this
  /// as an explicit itinerary projection, never as the event's display zone.
  public var timeZoneIdentifier: String?

  public init(
    id: UUID,
    name: String,
    latitude: Double,
    longitude: Double,
    regionName: String? = nil,
    kind: IdeaKind? = nil,
    url: String? = nil,
    phone: String? = nil,
    address: String? = nil,
    mapItemIdentifier: String? = nil,
    timeZoneIdentifier: String? = nil
  ) {
    self.id = id
    self.name = name
    self.latitude = latitude
    self.longitude = longitude
    self.regionName = regionName
    self.kind = kind
    self.url = url
    self.phone = phone
    self.address = address
    self.mapItemIdentifier = mapItemIdentifier
    self.timeZoneIdentifier = timeZoneIdentifier
  }

  /// One-line secondary text for a result row: the street address, else the city.
  public var subtitle: String { address ?? regionName ?? "" }
}

public struct PlaceSearchViewport: Equatable, Sendable {
  public let centerLatitude: Double
  public let centerLongitude: Double
  public let latitudeDelta: Double
  public let longitudeDelta: Double

  public init(
    centerLatitude: Double,
    centerLongitude: Double,
    latitudeDelta: Double,
    longitudeDelta: Double
  ) {
    self.centerLatitude = centerLatitude
    self.centerLongitude = centerLongitude
    self.latitudeDelta = latitudeDelta
    self.longitudeDelta = longitudeDelta
  }

  public init(region: MKCoordinateRegion) {
    self.init(
      centerLatitude: region.center.latitude,
      centerLongitude: region.center.longitude,
      latitudeDelta: region.span.latitudeDelta,
      longitudeDelta: region.span.longitudeDelta
    )
  }

  fileprivate var region: MKCoordinateRegion {
    MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: centerLatitude,
        longitude: centerLongitude
      ),
      span: MKCoordinateSpan(
        latitudeDelta: latitudeDelta,
        longitudeDelta: longitudeDelta
      )
    )
  }
}

enum PlaceSearchScope: Equatable, Sendable {
  case unavailable
  case worldwide
  case regions([MapRegion])
  case viewport(PlaceSearchViewport)
}

/// Injectable place search (STYLE.md §4 — location is a dependency, not a baked-in
/// API call). MapKit lives **only** behind this boundary, so the search is
/// overridable in tests/previews where `MKLocalSearch` can't run.
///
/// Uses `MKLocalSearch` with a **natural-language query** rather than
/// `MKLocalSearchCompleter`: the completer biases to the device's location (so a
/// famous-but-distant POI like Copenhagen's Noma never surfaces from California)
/// and handles combined "<name> <city>" fragments poorly. Natural-language search
/// is what Maps uses and is forgiving of "Noma Copenhagen". A caller may instead
/// supply one or more saved regions; those searches are required to stay inside
/// each region, not merely ranked toward it.
struct PlaceSearchClient: Sendable {
  var search: @Sendable (_ query: String, _ scope: PlaceSearchScope) async throws -> [Place]
}

extension PlaceSearchClient: DependencyKey {
  static let liveValue = PlaceSearchClient { query, scope in
    let searchRegions: [(region: MKCoordinateRegion, required: Bool)]
    switch scope {
    case .unavailable:
      return []
    case .worldwide:
      searchRegions = [(MKCoordinateRegion(MKMapRect.world), false)]
    case .regions(let regions):
      searchRegions = regions.map {
        (
          MKCoordinateRegion(
            center: CLLocationCoordinate2D(
              latitude: $0.centerLatitude,
              longitude: $0.centerLongitude
            ),
            span: MKCoordinateSpan(
              latitudeDelta: $0.latitudeDelta,
              longitudeDelta: $0.longitudeDelta
            )
          ),
          true
        )
      }
    case .viewport(let viewport):
      searchRegions = [(viewport.region, true)]
    }
    var found: [Place] = []
    var seen = Set<String>()
    for searchRegion in searchRegions {
      let response = try await MKLocalSearch(
        request: Self.request(
          query: query,
          region: searchRegion.region,
          required: searchRegion.required
        )
      )
      .start()
      for item in response.mapItems {
        let place = Place(mapItem: item)
        guard seen.insert(place.searchIdentity).inserted else { continue }
        found.append(place)
        if found.count == 12 { return found }
      }
    }
    return found
  }

  /// No network in tests/previews — override per case to supply fixtures.
  static let testValue = PlaceSearchClient { _, _ in [] }

  /// A non-empty region scope is deliberately strict: a trip's regions are its
  /// geographic contract, so a global same-name result must never leak in.
  private static func request(
    query: String,
    region: MKCoordinateRegion,
    required: Bool
  ) -> MKLocalSearch.Request {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    request.resultTypes = [.pointOfInterest, .address]
    request.region = region
    if required {
      request.regionPriority = .required
    }
    return request
  }
}

extension DependencyValues {
  var placeSearch: PlaceSearchClient {
    get { self[PlaceSearchClient.self] }
    set { self[PlaceSearchClient.self] = newValue }
  }
}

extension Place {
  /// Convert a human-confirmed Maps result into the capture merge's value boundary.
  /// Keeping this adapter beside `Place(mapItem:)` ensures the same provider facts
  /// reach web capture, map capture, and recommendation resolution.
  public func ideaCapture(id: Idea.ID? = nil) -> IdeaCapture {
    IdeaCapture(
      id: id,
      name: name,
      kind: kind,
      regionName: regionName,
      address: address,
      phone: phone,
      latitude: latitude,
      longitude: longitude,
      url: url ?? "",
      mapItemIdentifier: mapItemIdentifier
    )
  }

  /// MapKit's persistent ID is the best de-duplication key. A coordinate fallback
  /// keeps searches across overlapping trip regions from displaying one place twice.
  fileprivate var searchIdentity: String {
    mapItemIdentifier
      ?? "\(name)|\(latitude)|\(longitude)"
  }

  /// Map a MapKit result to our value boundary, using the iOS 26 `location` /
  /// `address` / `addressRepresentations` API (`placemark` is deprecated).
  /// Map a directly selected Apple Maps POI into the same value boundary as a
  /// text-search result. This lets map-first capture retain the POI's durable
  /// identity instead of re-searching by its displayed name.
  public init(mapItem item: MKMapItem) {
    self.init(
      id: UUID(),
      name: item.name ?? item.addressRepresentations?.cityName ?? "Location",
      latitude: item.location.coordinate.latitude,
      longitude: item.location.coordinate.longitude,
      regionName: item.addressRepresentations?.cityName
        ?? item.addressRepresentations?.regionName,
      kind: item.pointOfInterestCategory.flatMap {
        IdeaKind(pointOfInterestCategoryRawValue: $0.rawValue)
      },
      url: item.url?.absoluteString,
      phone: item.phoneNumber,
      address: item.address?.fullAddress,
      // The persistent POI identity (iOS 18+), the ADR-0019 dedup key; nil for a
      // geocoded address or other non-POI hit.
      mapItemIdentifier: item.identifier?.rawValue,
      timeZoneIdentifier: item.timeZone?.identifier
    )
  }
}

/// The callable recommendation-resolution operation. A future evaluation workspace
/// supplies the selected `Place`; this core performs the existing capture merge and
/// then links the already-committed candidate stop, in the caller's transaction.
public enum RecommendationResolution {
  @discardableResult
  public static func confirm(
    candidateStopID: TripIdea.ID,
    place: Place,
    in db: Database
  ) throws -> Idea.ID? {
    guard try TripIdea.find(candidateStopID).fetchOne(db) != nil else { return nil }
    let party = try TravelParty.ensureDefault(in: db)
    let resolution = try Idea.resolveCapture(
      place.ideaCapture(),
      travelPartyID: party.id,
      in: db
    )
    guard try TripIdea.attachResolvedIdea(resolution.ideaID, to: candidateStopID, in: db) != nil else {
      return nil
    }
    return resolution.ideaID
  }
}

/// The view-facing search state: the bound `query`, the `results` list, and the
/// debounce. The MapKit call itself is the injected `PlaceSearchClient`.
@MainActor
@Observable
public final class PlaceSearchModel {
  @ObservationIgnored @Dependency(\.placeSearch) private var placeSearch

  public private(set) var results: [Place] = []
  private(set) var searchTask: Task<Void, Never>?
  private var scope: PlaceSearchScope

  public var query = "" {
    didSet { scheduleSearch() }
  }

  /// Empty preserves the pool's worldwide lookup. The Ideas shopping surface
  /// supplies its selected trip/day regions so a new place is searched where that
  /// trip actually is.
  public init(regions: [MapRegion] = []) {
    scope = regions.isEmpty ? .worldwide : .regions(regions)
  }

  public init(viewport: PlaceSearchViewport?) {
    scope = viewport.map(PlaceSearchScope.viewport) ?? .unavailable
  }

  public func visibleRegionChanged(_ viewport: PlaceSearchViewport?) {
    let newScope = viewport.map(PlaceSearchScope.viewport) ?? .unavailable
    guard scope != newScope else { return }
    scope = newScope
    scheduleSearch()
  }

  public func cancelButtonTapped() {
    query = ""
  }

  public func resultTapped() {
    query = ""
  }

  private func scheduleSearch() {
    searchTask?.cancel()
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count >= 2, scope != .unavailable else {
      results = []
      return
    }
    // `MKLocalSearch` is throttled, so debounce keystrokes and cancel in-flight
    // searches rather than firing one per character.
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, let self else { return }
      await self.runSearch(text)
    }
  }

  private func runSearch(_ text: String) async {
    // Leave the last results in place on throttle/cancel/no-network rather than
    // flashing an empty list mid-typing.
    guard let found = try? await placeSearch.search(text, scope), !Task.isCancelled else { return }
    results = found
  }
}
