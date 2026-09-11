import Dependencies
import Foundation
import Observation

/// The device-location layer of one map, as a single value (`docs/STYLE.md` §3).
/// There is no "has a dot but also an error" state and no separate `isAuthorized`
/// flag to keep in step.
enum DeviceLocationState: Equatable, Sendable {
  /// Authorization hasn't been asked for. The map offers its own button, and
  /// tapping it is what asks (ADR-0046 §3).
  case offered
  /// The system prompt is up. The button stays put but is inert.
  case asking
  /// Authorized: the map draws the blue dot and the system location button.
  case tracking
  /// Denied, restricted, or Location Services off system-wide. No dot, no button,
  /// no complaint (ADR-0046 §4).
  case withheld
}

/// View-scoped owner of a map's device-location state. Held in a map view's
/// `@State`, it lives exactly as long as that view does — which is the whole
/// persistence story for location in this app (ADR-0046 §2): nothing here is
/// written to SQLite or handed to the sync engine.
///
/// It exists as a model rather than raw view state so the branch that decides
/// whether to prompt is testable, and so the client arrives by `@Dependency`
/// rather than being reached for from a view.
@MainActor
@Observable
final class DeviceLocationModel {
  private(set) var state: DeviceLocationState

  @ObservationIgnored @Dependency(\.locationClient) private var locationClient

  init() {
    @Dependency(\.locationClient) var locationClient
    self.state = Self.state(for: locationClient.authorization())
  }

  /// Re-read authorization without prompting — the user may have changed it in
  /// Settings while the app was away. Leaves a live prompt alone.
  func refresh() {
    guard state != .asking else { return }
    state = Self.state(for: locationClient.authorization())
  }

  /// The user tapped "show my location". Starting the stream is what raises the
  /// system prompt; we consume it only until the question is settled, then take
  /// the authorization value itself as the answer rather than trusting a reading
  /// that may have been emitted mid-prompt.
  ///
  /// Nothing keeps streaming afterwards: once authorized, MapKit's own
  /// `UserAnnotation` maintains the dot. A surface that needs the coordinate
  /// (the Today day map) consumes `LocationClient.updates` for itself.
  func locationButtonTapped() async {
    guard state == .offered else { return }
    state = .asking
    for await reading in locationClient.updates() {
      if reading == .awaitingAuthorization { continue }
      break
    }
    state = Self.state(for: locationClient.authorization())
  }

  private static func state(for authorization: LocationAuthorization) -> DeviceLocationState {
    switch authorization {
    case .notDetermined: .offered
    case .authorized: .tracking
    case .denied, .restricted: .withheld
    }
  }
}
