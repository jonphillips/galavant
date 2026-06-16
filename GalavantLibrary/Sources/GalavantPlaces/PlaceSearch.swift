import Dependencies
import Foundation
import GalavantSchema
import MapKit

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

  public init(
    id: UUID,
    name: String,
    latitude: Double,
    longitude: Double,
    regionName: String? = nil,
    kind: IdeaKind? = nil,
    url: String? = nil,
    phone: String? = nil,
    address: String? = nil
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
  }

  /// One-line secondary text for a result row: the street address, else the city.
  public var subtitle: String { address ?? regionName ?? "" }
}

/// Injectable place search (STYLE.md §4 — location is a dependency, not a baked-in
/// API call). MapKit lives **only** behind this boundary, so the search is
/// overridable in tests/previews where `MKLocalSearch` can't run.
///
/// Uses `MKLocalSearch` with a **natural-language query** over a **world-wide
/// region** rather than `MKLocalSearchCompleter`: the completer biases to the
/// device's location (so a famous-but-distant POI like Copenhagen's Noma never
/// surfaces from California) and handles combined "<name> <city>" fragments poorly.
/// Natural-language search is what Maps uses and is forgiving of "Noma Copenhagen".
struct PlaceSearchClient: Sendable {
  var search: @Sendable (_ query: String) async throws -> [Place]
}

extension PlaceSearchClient: DependencyKey {
  static let liveValue = PlaceSearchClient { query in
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    request.resultTypes = [.pointOfInterest, .address]
    // Don't bias to the device: search the whole world so a distant named place
    // ranks on its own merits.
    request.region = MKCoordinateRegion(MKMapRect.world)
    let response = try await MKLocalSearch(request: request).start()
    return response.mapItems.prefix(12).map(Place.init(mapItem:))
  }

  /// No network in tests/previews — override per case to supply fixtures.
  static let testValue = PlaceSearchClient { _ in [] }
}

extension DependencyValues {
  var placeSearch: PlaceSearchClient {
    get { self[PlaceSearchClient.self] }
    set { self[PlaceSearchClient.self] = newValue }
  }
}

extension Place {
  /// Map a MapKit result to our value boundary, using the iOS 26 `location` /
  /// `address` / `addressRepresentations` API (`placemark` is deprecated).
  init(mapItem item: MKMapItem) {
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
      address: item.address?.fullAddress
    )
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

  public var query = "" {
    didSet { scheduleSearch() }
  }

  public init() {}

  private func scheduleSearch() {
    searchTask?.cancel()
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count >= 2 else {
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
    guard let found = try? await placeSearch.search(text), !Task.isCancelled else { return }
    results = found
  }
}
