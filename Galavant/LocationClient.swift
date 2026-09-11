import CoreLocation
import Dependencies
import Foundation

/// Where the device is, as an injectable dependency (ADR-0046). Location in this
/// app is **ephemeral view state**: it is never written to SQLite, never registered
/// with the sync engine, and therefore never reaches CloudKit or the travel-party
/// share. Nothing here returns a persistable record — only a live stream a view
/// consumes for as long as it is on screen.
///
/// Shaped like `Trips/DirectionsClient.swift`: a `Sendable` struct of closures with
/// a `liveValue` and a deterministic `testValue`, not a manager object
/// (`docs/STYLE.md` §4).
struct LocationClient: Sendable {
  /// The app's current authorization, read **without prompting** — this is what
  /// lets a map decide whether to offer the location control at all.
  var authorization: @Sendable () -> LocationAuthorization

  /// Ephemeral device positions.
  ///
  /// Starting this stream is also what *asks* for when-in-use authorization the
  /// first time (`CLLocationUpdate.liveUpdates()` implicitly takes a when-in-use
  /// service session), which is why the UI must not start it before the user taps
  /// the location control — ADR-0046 §3. Cancelling the consuming task ends the
  /// session.
  var updates: @Sendable () -> AsyncStream<LocationReading>
}

/// Authorization as the UI needs to branch on it. `.authorized` covers both
/// when-in-use and always; the app never asks for always (ADR-0046 §1), so the
/// distinction would be a state we can't reach.
enum LocationAuthorization: Equatable, Sendable {
  case notDetermined
  case authorized
  /// The user said no, or Location Services are off system-wide.
  case denied
  /// Parental controls or MDM — the user *cannot* say yes.
  case restricted

  /// Whether offering a "show my location" control could ever lead anywhere.
  /// Denied and restricted both mean "show nothing, say nothing" (ADR-0046 §4).
  var canLocate: Bool {
    switch self {
    case .notDetermined, .authorized: true
    case .denied, .restricted: false
    }
  }
}

/// One reading from the device's location stream: either a position, or the reason
/// there isn't one. Deliberately not "an optional coordinate plus an error flag"
/// (`docs/STYLE.md` §3).
enum LocationReading: Equatable, Sendable {
  case located(latitude: Double, longitude: Double)
  /// The system is asking the user right now; there is no answer yet.
  case awaitingAuthorization
  /// Authorization was refused, or Location Services are off system-wide.
  case denied
  /// Parental controls or MDM prevent authorization.
  case restricted
  /// Authorized, but the device has no usable fix right now.
  case unavailable
}

extension LocationAuthorization {
  init(_ status: CLAuthorizationStatus) {
    switch status {
    case .notDetermined: self = .notDetermined
    case .authorizedWhenInUse, .authorizedAlways: self = .authorized
    case .denied: self = .denied
    case .restricted: self = .restricted
    @unknown default: self = .denied
    }
  }
}

extension LocationReading {
  /// Classify one `CLLocationUpdate`. The diagnostics are checked before the
  /// coordinate because an update carrying a stale location alongside
  /// `authorizationDenied` means "you are about to stop hearing from me."
  init(_ update: CLLocationUpdate) {
    if update.authorizationRestricted {
      self = .restricted
    } else if update.authorizationDenied || update.authorizationDeniedGlobally {
      self = .denied
    } else if update.authorizationRequestInProgress {
      self = .awaitingAuthorization
    } else if let location = update.location {
      self = .located(
        latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude)
    } else {
      self = .unavailable
    }
  }

  /// Whether this reading ends the stream: once the user has refused (or cannot
  /// grant) authorization there is nothing further to listen for.
  var isTerminal: Bool {
    switch self {
    case .denied, .restricted: true
    case .located, .awaitingAuthorization, .unavailable: false
    }
  }
}

extension LocationClient: DependencyKey {
  static var liveValue: LocationClient {
    LocationClient(
      authorization: {
        // A throwaway manager is the only way to read authorization without
        // starting a session; it registers no delegate and needs no run loop.
        LocationAuthorization(CLLocationManager().authorizationStatus)
      },
      updates: {
        AsyncStream { continuation in
          let task = Task {
            do {
              for try await update in CLLocationUpdate.liveUpdates() {
                let reading = LocationReading(update)
                continuation.yield(reading)
                if reading.isTerminal { break }
              }
            } catch {
              // A failed stream is indistinguishable to the UI from "no fix", and
              // ADR-0046 §4 says the map stays quiet either way.
              continuation.yield(.unavailable)
            }
            continuation.finish()
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      })
  }

  /// Deterministic stub: authorized, sitting on the Ortisei valley floor in the
  /// Dolomites, one reading and then silence. Keeps previews and tests free of
  /// CoreLocation and of the authorization prompt.
  static var testValue: LocationClient {
    LocationClient(
      authorization: { .authorized },
      updates: {
        AsyncStream { continuation in
          continuation.yield(.located(latitude: 46.5751, longitude: 11.6749))
          continuation.finish()
        }
      })
  }
}

extension DependencyValues {
  var locationClient: LocationClient {
    get { self[LocationClient.self] }
    set { self[LocationClient.self] = newValue }
  }
}
