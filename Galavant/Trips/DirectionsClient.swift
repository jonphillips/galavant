import Dependencies
import Foundation
import GalavantSchema
import MapKit

/// Injectable ETA client — wraps `MKDirections.calculateETA` for a given
/// transport mode between two itinerary stops. One request at a time (MKDirections
/// constraint); the model serialises calls through `fetchMissingETAs`.
struct DirectionsClient: Sendable {
  var calculateETA: @Sendable (LegKey, TransportMode) async throws -> TravelTime
}

extension TransportMode {
  var mkTransportType: MKDirectionsTransportType {
    switch self {
    case .walking: .walking
    case .transit: .transit
    case .driving: .automobile
    }
  }

  var mkDirectionsMode: String {
    switch self {
    case .walking: MKLaunchOptionsDirectionsModeWalking
    case .transit: MKLaunchOptionsDirectionsModeTransit
    case .driving: MKLaunchOptionsDirectionsModeDriving
    }
  }
}

extension DirectionsClient: DependencyKey {
  static var liveValue: DirectionsClient {
    DirectionsClient { leg, mode in
      let request = MKDirections.Request()
      request.transportType = mode.mkTransportType
      request.source = MKMapItem(
        location: CLLocation(latitude: leg.fromLat, longitude: leg.fromLon),
        address: nil)
      request.destination = MKMapItem(
        location: CLLocation(latitude: leg.toLat, longitude: leg.toLon),
        address: nil)
      let directions = MKDirections(request: request)
      return try await withCheckedThrowingContinuation { continuation in
        directions.calculateETA { response, error in
          if let error { continuation.resume(throwing: error); return }
          guard let response else { continuation.resume(throwing: CancellationError()); return }
          continuation.resume(returning: TravelTime(
            seconds: response.expectedTravelTime,
            meters: response.distance))
        }
      }
    }
  }

  /// Flat stub — 8 min walking, 25 min transit, 12 min driving. Keeps tests and
  /// previews deterministic without network calls.
  static var testValue: DirectionsClient {
    DirectionsClient { _, mode in
      switch mode {
      case .walking: TravelTime(seconds: 8 * 60, meters: 600)
      case .transit: TravelTime(seconds: 25 * 60, meters: 4000)
      case .driving: TravelTime(seconds: 12 * 60, meters: 4000)
      }
    }
  }
}

extension DependencyValues {
  var directionsClient: DirectionsClient {
    get { self[DirectionsClient.self] }
    set { self[DirectionsClient.self] = newValue }
  }
}
