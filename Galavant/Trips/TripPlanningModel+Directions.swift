import Dependencies
import GalavantSchema

extension TripPlanningModel {
  // MARK: - ETA mode resolution

  /// The effective transport mode for a leg — single-leg convenience over the pure
  /// `TripPlan.legMode` rule (override > trip default > auto-detect). It rebuilds
  /// the plan's leg-identity map for one lookup, so any caller resolving *many* legs
  /// must use `effectiveModes` (one pass) — never call this in a loop.
  func effectiveMode(for leg: LegKey) -> TransportMode {
    TripPlan.legMode(
      leg: leg, identity: plan.legIdentity(for: leg),
      overrides: currentModeOverrides, mainMode: trip?.mainTransportationMode,
      travelTimes: travelTimes, autoSwitchThreshold: Self.autoSwitchThreshold)
  }

  /// Pre-computed effective modes for all legs — passed into `itineraryItems` so the
  /// pure plan function doesn't call back into the model. Resolution now lives in
  /// `TripPlan.legModes`, which builds the leg-graph exactly once. (It previously
  /// resolved per leg here, rebuilding the graph every leg — O(legs²·days) per
  /// render and the itinerary lockup.)
  var effectiveModes: [LegKey: TransportMode] {
    plan.legModes(
      overrides: currentModeOverrides, mainMode: trip?.mainTransportationMode,
      travelTimes: travelTimes, autoSwitchThreshold: Self.autoSwitchThreshold)
  }

  // MARK: - ETA fetch

  /// Fetch ETAs for uncached legs, sequentially (MKDirections: one in-flight
  /// request at a time). A per-leg override or the shared trip default fetches
  /// that chosen mode directly. Otherwise the legacy automatic mode first fetches
  /// walking, then fetches transit for a long walk.
  /// If called while already running, enqueues one re-run for after.
  func fetchMissingETAs() async {
    if isFetchingETAs { pendingETAFetch = true; return }
    isFetchingETAs = true
    defer {
      isFetchingETAs = false
      if pendingETAFetch {
        pendingETAFetch = false
        Task { await fetchMissingETAs() }
      }
    }
    let plan = self.plan
    let identities = plan.legIdentities
    let overrides = currentModeOverrides
    for leg in plan.allLegs {
      guard !Task.isCancelled else { break }
      let identity = identities[leg]
      if let chosenMode = identity.flatMap({ overrides[$0] })
        ?? trip?.mainTransportationMode {
        if travelTimes[leg]?[chosenMode] == nil,
          let tt = try? await directionsClient.calculateETA(leg, chosenMode) {
          travelTimes[leg, default: [:]][chosenMode] = tt
        }
      } else {
        // Automatic trips retain walking as the baseline and prefetch transit
        // only when the walking time makes it the more useful default.
        if travelTimes[leg]?[.walking] == nil,
          let tt = try? await directionsClient.calculateETA(leg, .walking) {
          travelTimes[leg, default: [:]][.walking] = tt
        }
        guard !Task.isCancelled else { break }
        let walkingTime = travelTimes[leg]?[.walking]
        let longLeg = (walkingTime?.seconds ?? 0) >= Self.autoSwitchThreshold
        if longLeg, travelTimes[leg]?[.transit] == nil,
          let tt = try? await directionsClient.calculateETA(leg, .transit) {
          travelTimes[leg, default: [:]][.transit] = tt
        }
      }
    }
  }

  /// Persisted choices win after the in-memory projection has served the current
  /// interaction. Invalid future raw values gracefully fall back to the trip
  /// default rather than breaking all direction rows.
  var persistedModeOverrides: [LegIdentity: TransportMode] {
    allTravelModeOverrides
      .filter { $0.tripID == tripID }
      .reduce(into: [:]) { result, override in
        if let mode = override.mode { result[override.legIdentity] = mode }
      }
  }

  /// The mode map visible to scheduling heuristics, with the optimistic local
  /// projection taking precedence over the observed persisted rows.
  var currentModeOverrides: [LegIdentity: TransportMode] {
    persistedModeOverrides.merging(modeOverrides) { _, local in local }
  }

  /// User-override the transport mode for a leg. The choice is device-local and
  /// survives reopening this trip on this device; it is not registered with the
  /// CloudKit sync engine.
  func setMode(_ mode: TransportMode, for leg: LegKey) {
    guard let identity = plan.legIdentity(for: leg) else { return }
    modeOverrides[identity] = mode
    let tripID = tripID
    withErrorReporting {
      try database.write { db in
        try TripTravelModeOverride.setMode(mode, for: identity, tripID: tripID, in: db)
      }
    }
    Task { await fetchMissingETAs() }
  }
}
