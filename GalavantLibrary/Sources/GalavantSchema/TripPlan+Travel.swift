import Foundation

extension TripPlan {
  // MARK: - Travel-time connectors (docs/trip-canvas.md)

  /// All directed route segments across every day, in itinerary order — the set
  /// the directions client should pre-warm. Only pairs where both endpoints are
  /// located produce a leg.
  public var allLegs: [LegKey] {
    allLegPairs.map(\.leg)
  }

  /// Stable identities for the same coordinate legs exposed by `allLegs`.
  /// Coordinates remain the ETA cache key; identities are the persisted mode
  /// override key.
  public var legIdentities: [LegKey: LegIdentity] {
    Dictionary(
      allLegPairs.map { ($0.leg, $0.identity) },
      uniquingKeysWith: { first, _ in first })
  }

  public func legIdentity(for leg: LegKey) -> LegIdentity? {
    legIdentities[leg]
  }

  // MARK: - Effective transport modes

  /// The effective transport mode for every leg, resolved in a single pass. This
  /// lives in the pure core (not the model) so it is testable and, crucially, so
  /// the leg-identity map is built **once**: resolving legs one at a time rebuilds
  /// the whole graph per leg — the cause of the itinerary lockup (2026-08).
  ///
  /// Per-leg order: a leg override (the caller merges local-over-persisted into
  /// `overrides`) > the trip's `mainMode` > auto-detect (walk, upgraded to transit
  /// once the walking time reaches `autoSwitchThreshold`).
  public func legModes(
    overrides: [LegIdentity: TransportMode],
    mainMode: TransportMode?,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    autoSwitchThreshold: TimeInterval
  ) -> [LegKey: TransportMode] {
    legIdentities.reduce(into: [LegKey: TransportMode]()) { result, pair in
      result[pair.key] = Self.legMode(
        leg: pair.key, identity: pair.value, overrides: overrides,
        mainMode: mainMode, travelTimes: travelTimes,
        autoSwitchThreshold: autoSwitchThreshold)
    }
  }

  /// The per-leg resolution rule over already-built lookups — pure and O(1). A
  /// single-leg caller may reuse it; batch callers MUST use `legModes(_:)` rather
  /// than calling this in a loop (each `legIdentity(for:)` they'd need rebuilds the
  /// graph).
  public static func legMode(
    leg: LegKey,
    identity: LegIdentity?,
    overrides: [LegIdentity: TransportMode],
    mainMode: TransportMode?,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    autoSwitchThreshold: TimeInterval
  ) -> TransportMode {
    if let identity, let override = overrides[identity] { return override }
    if let mainMode { return mainMode }
    if let walking = travelTimes[leg]?[.walking], walking.seconds >= autoSwitchThreshold {
      return .transit
    }
    return .walking
  }

  private var allLegPairs: [(leg: LegKey, identity: LegIdentity)] {
    allLegPairs(
      itinerary: { itinerary },
      stays: { stays })
  }

  package func allLegPairs(
    itinerary deriveItinerary: () -> [ResolvedDay],
    stays deriveStays: () -> [ResolvedStay]
  ) -> [(leg: LegKey, identity: LegIdentity)] {
    let itinerary = deriveItinerary()
    let stays = deriveStays()
    return itinerary.flatMap { day in
      let dayStays = stays.filter { $0.stay.covers(day: day.number) }
      return legPairs(in: day.stops)
        + baseLegPairs(forDay: day.number, stops: day.stops, stays: dayStays)
        + returnLegPairs(forDay: day.number, stops: day.stops, stays: dayStays)
        + stayTransferLegPairs(forDay: day.number, stops: day.stops, stays: dayStays)
    }
  }

  /// Directed route segments between consecutive located stops on `day`.
  /// Iterates all stops in order — an unlocated stop between two located ones
  /// breaks the chain on both sides (no phantom A→C leg when B has no coords).
  public func legs(forDay day: Int) -> [LegKey] {
    legPairs(forDay: day).map(\.leg)
  }

  private func legPairs(forDay day: Int) -> [(leg: LegKey, identity: LegIdentity)] {
    let stops = itinerary.first(where: { $0.number == day })?.stops ?? []
    return legPairs(in: stops)
  }

  private func legPairs(in stops: [ResolvedStop]) -> [(leg: LegKey, identity: LegIdentity)] {
    return zip(stops, stops.dropFirst()).compactMap { a, b in
      guard
        let fromLat = a.content.latitude, let fromLon = a.content.longitude,
        let toLat = b.content.latitude, let toLon = b.content.longitude
      else { return nil }
      return (
        leg: LegKey(fromLat: fromLat, fromLon: fromLon, toLat: toLat, toLon: toLon),
        identity: LegIdentity(from: a.travelEndpointID, to: b.travelEndpointID))
    }
  }

  /// The located lodging → first-stop leg that is unambiguous in the day
  /// timeline. A normal lodging day uses its one base. On a changeover day, a
  /// first stop before check-in starts from the departing stay; one after it
  /// starts from the arriving stay.
  public func baseLegs(forDay day: Int) -> [LegKey] {
    baseLegPairs(forDay: day).map(\.leg)
  }

  private func baseLegPairs(forDay day: Int) -> [(leg: LegKey, identity: LegIdentity)] {
    let stops = itinerary.first(where: { $0.number == day })?.stops ?? []
    return baseLegPairs(forDay: day, stops: stops, stays: stays(coveringDay: day))
  }

  private func baseLegPairs(
    forDay day: Int,
    stops: [ResolvedStop],
    stays: [ResolvedStay]
  ) -> [(leg: LegKey, identity: LegIdentity)] {
    guard let route = lodgingToStopRoute(
      forDay: day, stops: stops, stays: stays)
    else { return [] }
    return [(route.leg, route.identity)]
  }

  /// The last located stop → lodging leg that is unambiguous in the day
  /// timeline. A normal lodging day returns to its one base. On a changeover
  /// day, the last located stop returns to the arriving stay.
  public func returnLegs(forDay day: Int) -> [LegKey] {
    returnLegPairs(forDay: day).map(\.leg)
  }

  private func returnLegPairs(forDay day: Int) -> [(leg: LegKey, identity: LegIdentity)] {
    let stops = itinerary.first(where: { $0.number == day })?.stops ?? []
    return returnLegPairs(forDay: day, stops: stops, stays: stays(coveringDay: day))
  }

  private func returnLegPairs(
    forDay day: Int,
    stops: [ResolvedStop],
    stays: [ResolvedStay]
  ) -> [(leg: LegKey, identity: LegIdentity)] {
    guard let route = stopToLodgingRoute(
      forDay: day, stops: stops, stays: stays)
    else { return [] }
    return [(route.leg, route.identity)]
  }

  /// A direct lodging transfer appears when check-out and check-in are adjacent
  /// in the timeline. Stops before check-out or after check-in do not suppress
  /// it; only a scheduled stop *between* those events does.
  public func stayTransferLegs(forDay day: Int) -> [LegKey] {
    stayTransferLegPairs(forDay: day).map(\.leg)
  }

  private func stayTransferLegPairs(forDay day: Int) -> [(leg: LegKey, identity: LegIdentity)] {
    stayTransferLegPairs(
      forDay: day,
      stops: itinerary.first(where: { $0.number == day })?.stops ?? [],
      stays: stays(coveringDay: day))
  }

  private func stayTransferLegPairs(
    forDay day: Int,
    stops: [ResolvedStop],
    stays: [ResolvedStay]
  ) -> [(leg: LegKey, identity: LegIdentity)] {
    guard let transfer = stayTransfer(
      forDay: day,
      stops: stops,
      stays: stays)
    else { return [] }
    return [(transfer.leg, transfer.identity)]
  }

  /// The direct lodging transfer on `day`, if the two stay boundaries are
  /// adjacent in the day's timeline. This is the shared transfer-day fact used
  /// by itinerary rows and the Journey/Today projections.
  public func transferConnector(
    forDay day: Int,
    travelTimes: [LegKey: [TransportMode: TravelTime]] = [:],
    effectiveModes: [LegKey: TransportMode] = [:]
  ) -> TravelConnector? {
    let stops = itinerary.first(where: { $0.number == day })?.stops ?? []
    return stayTransferConnector(
      forDay: day,
      stops: stops,
      stays: stays(coveringDay: day),
      travelTimes: travelTimes,
      effectiveModes: effectiveModes)
  }

  func baseConnector(
    forDay day: Int,
    stops: [ResolvedStop],
    stays: [ResolvedStay],
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    effectiveModes: [LegKey: TransportMode]
  ) -> TravelConnector? {
    guard let route = lodgingToStopRoute(forDay: day, stops: stops, stays: stays) else { return nil }
    let mode = effectiveModes[route.leg] ?? .walking
    return TravelConnector(
      from: route.from,
      to: route.to,
      leg: route.leg,
      mode: mode,
      travelTime: travelTimes[route.leg]?[mode],
      kind: .fromLodging
    )
  }

  func returnConnector(
    forDay day: Int,
    stops: [ResolvedStop],
    stays: [ResolvedStay],
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    effectiveModes: [LegKey: TransportMode]
  ) -> TravelConnector? {
    guard let route = stopToLodgingRoute(forDay: day, stops: stops, stays: stays) else { return nil }
    let mode = effectiveModes[route.leg] ?? .walking
    return TravelConnector(
      from: route.from,
      to: route.to,
      leg: route.leg,
      mode: mode,
      travelTime: travelTimes[route.leg]?[mode],
      kind: .toLodging
    )
  }

  func stayTransferConnector(
    forDay day: Int,
    stops: [ResolvedStop],
    stays: [ResolvedStay],
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    effectiveModes: [LegKey: TransportMode]
  ) -> TravelConnector? {
    guard let transfer = stayTransfer(forDay: day, stops: stops, stays: stays) else { return nil }
    let mode = effectiveModes[transfer.leg] ?? .walking
    return TravelConnector(
      from: transfer.from,
      to: transfer.to,
      leg: transfer.leg,
      mode: mode,
      travelTime: travelTimes[transfer.leg]?[mode],
      kind: .betweenLodgings
    )
  }

  private func lodgingToStopRoute(
    forDay day: Int, stops: [ResolvedStop], stays: [ResolvedStay]
  ) -> (from: TravelEndpoint, to: TravelEndpoint, leg: LegKey, identity: LegIdentity)? {
    let sortKeys = TripIdea.effectiveIntraDaySort(stops.map(\.entry))
    let base: ResolvedStay?
    let destination = stops.first(where: isLocated)
    if stays.count == 1 {
      base = stays[0]
    } else {
      let departures = stays.filter { $0.stay.checkOutDay == day }
      let arrivals = stays.filter { $0.stay.checkInDay == day }
      guard let destination, departures.count == 1, arrivals.count == 1 else { return nil }
      base = (sortKeys[destination.id] ?? .max) > arrivals[0].stay.checkInSortMinutes
        ? arrivals[0]
        : departures[0]
    }
    guard let base, let destination, let from = endpoint(for: base) else { return nil }
    let to = endpoint(for: destination)
    return (
      from: from,
      to: to,
      leg: LegKey(
        fromLat: from.latitude, fromLon: from.longitude,
        toLat: to.latitude, toLon: to.longitude),
      identity: LegIdentity(from: base.travelEndpointID, to: destination.travelEndpointID)
    )
  }

  private func stopToLodgingRoute(
    forDay day: Int, stops: [ResolvedStop], stays: [ResolvedStay]
  ) -> (from: TravelEndpoint, to: TravelEndpoint, leg: LegKey, identity: LegIdentity)? {
    guard let origin = stops.last(where: isLocated) else { return nil }
    let destination: ResolvedStay?
    if stays.count == 1 {
      guard stays[0].stay.checkOutDay != day else { return nil }
      destination = stays[0]
    } else {
      let arrivals = stays.filter { $0.stay.checkInDay == day }
      guard arrivals.count == 1 else { return nil }
      destination = arrivals[0]
    }
    guard let destination, let to = endpoint(for: destination) else { return nil }
    let from = endpoint(for: origin)
    return (
      from: from,
      to: to,
      leg: LegKey(
        fromLat: from.latitude, fromLon: from.longitude,
        toLat: to.latitude, toLon: to.longitude),
      identity: LegIdentity(from: origin.travelEndpointID, to: destination.travelEndpointID)
    )
  }

  private func stayTransfer(
    forDay day: Int, stops: [ResolvedStop], stays: [ResolvedStay]
  ) -> (from: TravelEndpoint, to: TravelEndpoint, leg: LegKey, identity: LegIdentity)? {
    let leaving = stays.filter { $0.stay.checkOutDay == day }
    let arriving = stays.filter { $0.stay.checkInDay == day }
    guard
      leaving.count == 1,
      arriving.count == 1,
      leaving[0].id != arriving[0].id,
      leaving[0].stay.checkOutSortMinutes <= arriving[0].stay.checkInSortMinutes,
      let from = endpoint(for: leaving[0]),
      let to = endpoint(for: arriving[0])
    else { return nil }
    let sortKeys = TripIdea.effectiveIntraDaySort(stops.map(\.entry))
    let hasIntermediateStop = stops.contains { stop in
      let key = sortKeys[stop.id] ?? .max
      return key >= leaving[0].stay.checkOutSortMinutes && key <= arriving[0].stay.checkInSortMinutes
    }
    guard !hasIntermediateStop else { return nil }
    return (
      from: from,
      to: to,
      leg: LegKey(
        fromLat: from.latitude, fromLon: from.longitude,
        toLat: to.latitude, toLon: to.longitude),
      identity: LegIdentity(from: leaving[0].travelEndpointID, to: arriving[0].travelEndpointID)
    )
  }

  private func isLocated(_ stop: ResolvedStop) -> Bool {
    stop.content.latitude != nil && stop.content.longitude != nil
  }

  func endpoint(for stop: ResolvedStop) -> TravelEndpoint {
    TravelEndpoint(
      id: stop.travelEndpointID, title: stop.content.title,
      latitude: stop.content.latitude!, longitude: stop.content.longitude!)
  }

  private func endpoint(for stay: ResolvedStay) -> TravelEndpoint? {
    guard let latitude = stay.content.latitude, let longitude = stay.content.longitude else { return nil }
    return TravelEndpoint(
      id: stay.travelEndpointID, title: stay.content.title,
      latitude: latitude, longitude: longitude)
  }

  /// The ordered geographic endpoints for a day's route: lodging (when the
  /// first leg is unambiguous), located stops in itinerary order, then lodging
  /// (when the return leg is unambiguous). The same connector resolution that
  /// powers timeline rows supplies both lodging endpoints.
  public func routeEndpoints(forDay day: Int) -> [TravelEndpoint] {
    let stops = itinerary.first(where: { $0.number == day })?.stops ?? []
    let dayStays = stays(coveringDay: day)
    let base = baseConnector(
      forDay: day, stops: stops, stays: dayStays, travelTimes: [:], effectiveModes: [:])
    let returning = returnConnector(
      forDay: day, stops: stops, stays: dayStays, travelTimes: [:], effectiveModes: [:])
    var endpoints = base.map { [$0.from] } ?? []
    endpoints += stops.filter(isLocated).map(endpoint(for:))
    if let returning { endpoints.append(returning.to) }
    return endpoints
  }
}

extension ResolvedStop {
  /// The stable endpoint identity for a stop. All members of an alternatives
  /// ring intentionally share the ring identity.
  public var travelEndpointID: String {
    if let groupID = entry.alternativeGroupID {
      return "ring-\(groupID)"
    }
    return "stop-\(id)"
  }
}

extension ResolvedStay {
  public var travelEndpointID: String { "stay-\(id)" }
}

extension TripPlan {
  /// Carry the moved stop's outgoing mode onto its new successor. This is a
  /// deliberately small heuristic: incoming legs and unrelated new legs are
  /// left alone, while a changed outgoing successor gets the old outgoing mode.
  public static func carryOutgoingOnMove(
    movedEndpointID: String,
    overrides: [LegIdentity: TransportMode],
    beforeLegs: [LegIdentity],
    afterLegs: [LegIdentity]
  ) -> [(leg: LegIdentity, mode: TransportMode)] {
    guard
      let before = beforeLegs.first(where: { $0.from == movedEndpointID }),
      let after = afterLegs.first(where: { $0.from == movedEndpointID }),
      before.to != after.to,
      let mode = overrides[before]
    else { return [] }
    return [(leg: after, mode: mode)]
  }
}
