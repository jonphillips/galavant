import Dependencies
import GalavantSchema

extension TripPlanningModel {
  /// Persisted choices win after the in-memory projection has served the current
  /// interaction. Invalid future raw values gracefully fall back to the trip
  /// default rather than breaking all direction rows.
  var persistedModeOverrides: [LegKey: TransportMode] {
    allTravelModeOverrides
      .filter { $0.tripID == tripID }
      .reduce(into: [:]) { result, override in
        if let mode = override.mode { result[override.leg] = mode }
      }
  }

  /// User-override the transport mode for a leg. The choice is a shared trip
  /// fact, so reopening the trip—or opening it on the other device—keeps it.
  func setMode(_ mode: TransportMode, for leg: LegKey) {
    modeOverrides[leg] = mode
    let tripID = tripID
    withErrorReporting {
      try database.write { db in
        try TripTravelModeOverride.setMode(mode, for: leg, tripID: tripID, in: db)
      }
    }
    Task { await fetchMissingETAs() }
  }
}
