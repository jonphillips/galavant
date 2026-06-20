import Dependencies
import Foundation
import GalavantSchema
import MapKit

/// Injectable ETA client — wraps `MKDirections.calculateETA` for walking travel
/// times between itinerary stops. Walking is the right default for urban trip
/// planning; no per-trip transport type setting yet.
struct DirectionsClient: Sendable {
  var calculateETA: @Sendable (LegKey) async throws -> TravelTime
}

extension DirectionsClient: DependencyKey {
  static var liveValue: DirectionsClient {
    DirectionsClient { leg in
      let request = MKDirections.Request()
      request.transportType = .walking
      request.source = MKMapItem(
        location: CLLocation(latitude: leg.fromLat, longitude: leg.fromLon),
        address: nil)
      request.destination = MKMapItem(
        location: CLLocation(latitude: leg.toLat, longitude: leg.toLon),
        address: nil)
      let directions = MKDirections(request: request)
      return try await withCheckedThrowingContinuation { continuation in
        directions.calculateETA { response, error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          guard let response else {
            continuation.resume(throwing: CancellationError())
            return
          }
          continuation.resume(returning: TravelTime(
            seconds: response.expectedTravelTime,
            meters: response.distance))
        }
      }
    }
  }

  /// Flat stub — always 8 min, 600 m. Keeps tests and previews deterministic;
  /// the parser/matching paths are the tested surfaces.
  static var testValue: DirectionsClient {
    DirectionsClient { _ in TravelTime(seconds: 8 * 60, meters: 600) }
  }
}

extension DependencyValues {
  var directionsClient: DirectionsClient {
    get { self[DirectionsClient.self] }
    set { self[DirectionsClient.self] = newValue }
  }
}
