import CoreLocation
import Dependencies
import Foundation
import Testing

@testable import Galavant

/// Mutable state shared with a stub client's `@Sendable` closures. These tests
/// drive the stub from one task at a time, so a bare box is honest about what is
/// going on and keeps the file free of a locking type.
private final class Box<Value>: @unchecked Sendable {
  var value: Value
  init(_ value: Value) { self.value = value }
}

/// The device-location layer (ADR-0046). What is worth pinning down here is the
/// *prompting* branch — that the app asks exactly once, only on a tap, and that a
/// refusal settles into the silent state — plus the classification of a raw
/// `CLLocationUpdate`, which is the one place a CoreLocation value becomes an
/// app value.
@MainActor
struct DeviceLocationModelTests {
  /// A client whose authorization answer can change between calls, so a test can
  /// model the user answering the system prompt.
  private static func client(
    authorization: @escaping @Sendable () -> LocationAuthorization,
    readings: [LocationReading] = []
  ) -> LocationClient {
    LocationClient(
      authorization: authorization,
      updates: {
        AsyncStream { continuation in
          for reading in readings { continuation.yield(reading) }
          continuation.finish()
        }
      })
  }

  @Test func offersTheButtonWhenAuthorizationHasNotBeenAsked() {
    let model = withDependencies {
      $0.locationClient = Self.client(authorization: { .notDetermined })
    } operation: {
      DeviceLocationModel()
    }
    #expect(model.state == .offered)
  }

  /// The dot appears without a tap when the user has already said yes — there is
  /// no prompt left to avoid.
  @Test func tracksImmediatelyWhenAlreadyAuthorized() {
    let model = withDependencies {
      $0.locationClient = Self.client(authorization: { .authorized })
    } operation: {
      DeviceLocationModel()
    }
    #expect(model.state == .tracking)
  }

  @Test(arguments: [LocationAuthorization.denied, .restricted])
  func showsNothingWhenLocationIsWithheld(_ authorization: LocationAuthorization) {
    let model = withDependencies {
      $0.locationClient = Self.client(authorization: { authorization })
    } operation: {
      DeviceLocationModel()
    }
    #expect(model.state == .withheld)
  }

  /// Opening a map must never start the stream — that is what raises the system
  /// prompt, and ADR-0046 §3 says only a tap may do that.
  @Test func initializingAndRefreshingNeverStartTheStream() {
    let started = Box(0)
    let client = LocationClient(
      authorization: { .notDetermined },
      updates: {
        started.value += 1
        return AsyncStream { $0.finish() }
      })
    let model = withDependencies { $0.locationClient = client } operation: {
      DeviceLocationModel()
    }
    model.refresh()
    #expect(started.value == 0)
    #expect(model.state == .offered)
  }

  /// Tapping asks, the user grants, the map starts drawing the dot. The reading
  /// while the prompt is up is skipped, not treated as an answer.
  @Test func tappingTheButtonAsksAndThenTracksWhenGranted() async {
    let answered = Box(false)
    let client = LocationClient(
      authorization: { answered.value ? .authorized : .notDetermined },
      updates: {
        AsyncStream { continuation in
          continuation.yield(.awaitingAuthorization)
          answered.value = true
          continuation.yield(.located(latitude: 46.5751, longitude: 11.6749))
          continuation.finish()
        }
      })
    let model = withDependencies { $0.locationClient = client } operation: {
      DeviceLocationModel()
    }
    #expect(model.state == .offered)
    await model.locationButtonTapped()
    #expect(model.state == .tracking)
  }

  @Test func tappingTheButtonAndBeingRefusedGoesQuiet() async {
    let answered = Box(false)
    let client = LocationClient(
      authorization: { answered.value ? .denied : .notDetermined },
      updates: {
        AsyncStream { continuation in
          continuation.yield(.awaitingAuthorization)
          answered.value = true
          continuation.yield(.denied)
          continuation.finish()
        }
      })
    let model = withDependencies { $0.locationClient = client } operation: {
      DeviceLocationModel()
    }
    await model.locationButtonTapped()
    #expect(model.state == .withheld)
  }

  /// Once the question is settled, the button is the system's and the app's own
  /// prompting path is closed — a stray call must not reopen a session.
  @Test func tappingOnceSettledDoesNotAskAgain() async {
    let started = Box(0)
    let client = LocationClient(
      authorization: { .authorized },
      updates: {
        started.value += 1
        return AsyncStream { $0.finish() }
      })
    let model = withDependencies { $0.locationClient = client } operation: {
      DeviceLocationModel()
    }
    #expect(model.state == .tracking)
    await model.locationButtonTapped()
    #expect(started.value == 0)
    #expect(model.state == .tracking)
  }

  /// A user who flips the switch in Settings while the app is away is picked up
  /// on the way back in, without a prompt.
  @Test func refreshPicksUpAuthorizationGrantedInSettings() {
    let granted = Box(false)
    let client = Self.client(authorization: { granted.value ? .authorized : .notDetermined })
    let model = withDependencies { $0.locationClient = client } operation: {
      DeviceLocationModel()
    }
    #expect(model.state == .offered)
    granted.value = true
    model.refresh()
    #expect(model.state == .tracking)
  }
}

/// Mapping CoreLocation's values onto the app's. Authorization is a plain
/// translation; a reading is a precedence rule, because one update can carry a
/// stale coordinate alongside the diagnostic that says it is the last one.
struct LocationClientMappingTests {
  @Test func authorizationMapsEveryStatus() {
    #expect(LocationAuthorization(.notDetermined) == .notDetermined)
    #expect(LocationAuthorization(.authorizedWhenInUse) == .authorized)
    #expect(LocationAuthorization(.authorizedAlways) == .authorized)
    #expect(LocationAuthorization(.denied) == .denied)
    #expect(LocationAuthorization(.restricted) == .restricted)
  }

  @Test func onlyNotDeterminedAndAuthorizedAreWorthOfferingAControlFor() {
    #expect(LocationAuthorization.notDetermined.canLocate)
    #expect(LocationAuthorization.authorized.canLocate)
    #expect(!LocationAuthorization.denied.canLocate)
    #expect(!LocationAuthorization.restricted.canLocate)
  }

  /// Refusal ends the stream; a missing fix does not.
  @Test func refusalIsTerminalAndAMissingFixIsNot() {
    #expect(LocationReading.denied.isTerminal)
    #expect(LocationReading.restricted.isTerminal)
    #expect(!LocationReading.unavailable.isTerminal)
    #expect(!LocationReading.awaitingAuthorization.isTerminal)
    #expect(!LocationReading.located(latitude: 0, longitude: 0).isTerminal)
  }
}
