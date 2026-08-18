import Dependencies
import GalavantSchema

extension TripPlanningModel {
  // MARK: - ETA mode resolution

  /// The effective transport mode for a leg: user override > trip default >
  /// auto-detect. Auto-detect keeps the original walking ≥ 20 min → transit
  /// behavior for existing trips whose shared default is still unset.
  func effectiveMode(for leg: LegKey) -> TransportMode {
    if let identity = plan.legIdentity(for: leg) {
      if let override = modeOverrides[identity] { return override }
      if let override = persistedModeOverrides[identity] { return override }
    }
    if let mainMode = trip?.mainTransportationMode { return mainMode }
    if let walking = travelTimes[leg]?[.walking],
      walking.seconds >= Self.autoSwitchThreshold {
      return .transit
    }
    return .walking
  }

  /// Pre-computed effective modes for all legs — passed into `itineraryItems`
  /// so the pure plan function doesn't need to call back into the model.
  var effectiveModes: [LegKey: TransportMode] {
    Dictionary(plan.allLegs.map { ($0, effectiveMode(for: $0)) },
               uniquingKeysWith: { first, _ in first })
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
    for leg in plan.allLegs {
      guard !Task.isCancelled else { break }
      let identity = plan.legIdentity(for: leg)
      if let chosenMode = identity.flatMap({ modeOverrides[$0] ?? persistedModeOverrides[$0] })
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

  /// User-override the transport mode for a leg. The choice is a shared trip
  /// fact, so reopening the trip—or opening it on the other device—keeps it.
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
