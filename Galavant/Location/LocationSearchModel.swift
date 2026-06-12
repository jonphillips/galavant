import Foundation
import MapKit

/// A resolved place: what we pull out of a map search to populate an idea.
struct ResolvedPlace: Equatable {
  var name: String
  var latitude: Double
  var longitude: Double
  var regionName: String?
}

/// Wraps `MKLocalSearchCompleter` (delegate-based, so it stays a reference type)
/// and resolves a chosen completion to coordinates via async `MKLocalSearch`.
/// Adapted from V2's `MKLocalSearchService`.
@MainActor
@Observable
final class LocationSearchModel: NSObject, MKLocalSearchCompleterDelegate {
  private let completer = MKLocalSearchCompleter()
  private(set) var results: [MKLocalSearchCompletion] = []

  var query = "" {
    didSet {
      if query.isEmpty {
        results = []
      } else {
        completer.queryFragment = query
      }
    }
  }

  override init() {
    super.init()
    completer.resultTypes = [.address, .pointOfInterest]
    completer.pointOfInterestFilter = .includingAll
    completer.delegate = self
  }

  func resolve(_ completion: MKLocalSearchCompletion) async -> ResolvedPlace? {
    let request = MKLocalSearch.Request(completion: completion)
    guard
      let item = try? await MKLocalSearch(request: request).start().mapItems.first
    else { return nil }
    let placemark = item.placemark
    return ResolvedPlace(
      name: item.name ?? completion.title,
      latitude: placemark.coordinate.latitude,
      longitude: placemark.coordinate.longitude,
      regionName: placemark.locality ?? placemark.administrativeArea
    )
  }

  // MKLocalSearchCompleter delivers these on the main thread. Read `self.completer`
  // (a MainActor property) rather than the sending parameter to satisfy Swift 6.
  nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
    MainActor.assumeIsolated { self.results = self.completer.results }
  }

  nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
    MainActor.assumeIsolated { self.results = [] }
  }
}
