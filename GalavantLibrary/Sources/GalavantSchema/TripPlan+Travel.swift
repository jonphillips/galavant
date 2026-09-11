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
      return routeLegs(forDay: day.number, stops: day.stops, stays: dayStays)
        .map { ($0.leg, $0.identity) }
    }
  }

  // MARK: - The day's located-waypoint chain

  /// One directed leg on a day's physical route, tagged with the row its
  /// connector renders against. The whole travel story of a day — the ETA leg
  /// set (`allLegs`), the itinerary's direction rows, and the canvas polyline —
  /// is derived from this one chain, so the three cannot tell different stories.
  ///
  /// A leg exists between two *consecutive located waypoints* of the day. There
  /// are no special cases per lodging shape: a stop, a stay boundary, a home-base
  /// row, and (were it ever located) a calendar constraint are all just waypoints,
  /// and `kind` is a *classification* of the endpoints, not a gate on whether the
  /// leg exists (ADR — dogfood Slice C).
  struct RouteLeg {
    var from: TravelEndpoint
    var to: TravelEndpoint
    var kind: TravelConnector.Kind
    /// The index, in the day's ordered event rows, of the row this connector
    /// renders immediately *before* — or nil for the return-to-base leg, whose
    /// destination is drawn once (atop the day or earlier in the stream) and so
    /// trails the day's last stop row instead.
    var toRowIndex: Int?

    var leg: LegKey {
      LegKey(
        fromLat: from.latitude, fromLon: from.longitude,
        toLat: to.latitude, toLon: to.longitude)
    }
    var identity: LegIdentity { LegIdentity(from: from.id, to: to.id) }
  }

  static func legKind(fromBase: Bool, toBase: Bool) -> TravelConnector.Kind {
    switch (fromBase, toBase) {
    case (true, false): .fromLodging
    case (false, true): .toLodging
    case (true, true): .betweenLodgings
    case (false, false): .betweenStops
    }
  }

  /// The day's directed legs in render order, derived once from the woven event
  /// stream. Walks the ordered rows into located waypoints (a located stop, a
  /// located stay boundary, a located home base) plus the *gaps* an unlocated
  /// stop leaves, then connects each consecutive pair.
  ///
  /// Two properties fall out of one rule rather than four hand-written cases:
  /// - **A gap breaks a stop→stop chain but not a lodging bracket.** An unlocated
  ///   stop between two located stops kills the leg (there is no honest route
  ///   through a place with no coordinate), yet a base still reaches the first or
  ///   last located stop across such a gap — the leg has a real endpoint at the
  ///   lodging either way.
  /// - **Suppression is adjacency.** A direct hotel→hotel transfer appears only
  ///   when the two boundaries are adjacent in the stream; a stop scheduled
  ///   between check-out and check-in simply sits between them as a waypoint, so
  ///   no direct leg is emitted — no explicit "is there an intermediate stop"
  ///   test is needed.
  func routeLegs(
    forDay day: Int, stops: [ResolvedStop], stays: [ResolvedStay]
  ) -> [RouteLeg] {
    let rows = orderedEventRows(forDay: day, stops: stops, stays: stays)

    enum Token {
      case waypoint(endpoint: TravelEndpoint, isBase: Bool, rowIndex: Int)
      /// An unlocated stop: a break in the stop→stop chain, but transparent to a
      /// lodging bracket reaching past it to the first/last *located* stop.
      case stopGap
    }
    var tokens: [Token] = []
    for (index, row) in rows.enumerated() {
      switch row {
      case let .stop(stop):
        if let endpoint = locatedEndpoint(for: stop) {
          tokens.append(.waypoint(endpoint: endpoint, isBase: false, rowIndex: index))
        } else {
          tokens.append(.stopGap)
        }
      case let .checkIn(stay), let .checkOut(stay), let .homeBase(stay):
        if let endpoint = endpoint(for: stay) {
          tokens.append(.waypoint(endpoint: endpoint, isBase: true, rowIndex: index))
        }
        // An unlocated stay (freeform, no coordinate) is transparent — it takes
        // no leg down with it (dogfood Slice C, gap 5).
      case .calendarConstraint, .connector, .nowMarker:
        break  // non-spatial rows are transparent to the route
      }
    }

    // The base you sleep at tonight, appended as the return target unless the day
    // already ends on it. A middle-day base is drawn atop the day and a
    // changeover's arriving base already closes the stream, so both need the
    // explicit return; a pure check-out day sleeps nowhere located and gets none.
    if let returnBase = nightBase(forDay: day, stays: stays),
      let endpoint = endpoint(for: returnBase) {
      let lastWaypointID = tokens.reversed().lazy.compactMap { token -> String? in
        if case let .waypoint(waypoint, _, _) = token { return waypoint.id }
        return nil
      }.first
      // Only append the return target when the day does not already *end* on it
      // (a changeover's arriving base closes the stream); the base appearing atop
      // the day as a home-base row does not count.
      if lastWaypointID != endpoint.id {
        tokens.append(.waypoint(endpoint: endpoint, isBase: true, rowIndex: -1))
      }
    }

    var legs: [RouteLeg] = []
    var previous: (endpoint: TravelEndpoint, isBase: Bool)?
    var sawStopGap = false
    for token in tokens {
      switch token {
      case .stopGap:
        sawStopGap = true
      case let .waypoint(endpoint, isBase, rowIndex):
        if let previous {
          let bothStops = !previous.isBase && !isBase
          if !(bothStops && sawStopGap) {
            legs.append(RouteLeg(
              from: previous.endpoint, to: endpoint,
              kind: Self.legKind(fromBase: previous.isBase, toBase: isBase),
              toRowIndex: rowIndex < 0 ? nil : rowIndex))
          }
        }
        previous = (endpoint, isBase)
        sawStopGap = false
      }
    }
    return legs
  }

  /// The located stay you spend the night of `day` in — a stay that covers the
  /// day and does not check out on it. Prefers a stay arriving today (the new
  /// hotel on a changeover) over a middle-day base you're already in.
  private func nightBase(forDay day: Int, stays: [ResolvedStay]) -> ResolvedStay? {
    let nightStays = stays.filter {
      $0.stay.covers(day: day) && $0.stay.checkOutDay != day && endpoint(for: $0) != nil
    }
    return nightStays.first { $0.stay.checkInDay == day } ?? nightStays.first
  }

  /// The day's ordered event rows *before* connectors and the now-marker are
  /// woven in: the home-base rows that lead the day, then stops, stay boundaries,
  /// and calendar constraints sorted by their intra-day time. This ordering is
  /// the single source of truth both the itinerary weave and `routeLegs` read, so
  /// the direction rows and the ETA leg set can never disagree.
  ///
  /// Ranks break ties against a same-minute stop: an all-day constraint leads,
  /// then check-out (you leave in the morning), a timed constraint, the stop
  /// itself, then check-in (you arrive in the evening). A stable order index
  /// keeps same-ranked rows in their input order.
  func orderedEventRows(
    forDay day: Int, stops: [ResolvedStop], stays: [ResolvedStay]
  ) -> [ItineraryItem] {
    enum TieBreak: Int {
      case allDayContext
      case checkOut
      case calendarConstraint
      case stop
      case checkIn
    }
    struct Row { let key: Int; let rank: TieBreak; let order: Int; let item: ItineraryItem }
    var boundaries: [Row] = []
    var homeBaseRows: [ItineraryItem] = []
    for resolved in stays {
      let stay = resolved.stay
      if stay.checkOutDay == day {
        boundaries.append(Row(
          key: stay.checkOutSortMinutes, rank: .checkOut, order: boundaries.count,
          item: .checkOut(resolved)))
      }
      if stay.checkInDay == day {
        boundaries.append(Row(
          key: stay.checkInSortMinutes, rank: .checkIn, order: boundaries.count,
          item: .checkIn(resolved)))
      }
      if stay.checkInDay != day, stay.checkOutDay != day {
        homeBaseRows.append(.homeBase(resolved))  // covered middle day
      }
    }
    let constraints = calendarConstraints.filter { $0.dayNumber == day }
    boundaries += constraints.enumerated().map { offset, constraint in
      Row(
        key: constraint.intraDaySortMinutes,
        rank: constraint.isAllDay ? .allDayContext : .calendarConstraint,
        order: boundaries.count + offset,
        item: .calendarConstraint(constraint))
    }

    // A day with no stops, constraints, stay boundaries, or home base has no timeline.
    guard !stops.isEmpty || !boundaries.isEmpty || !homeBaseRows.isEmpty else { return [] }

    // Stops carry their *effective* intra-day key (ADR-0033: an Anytime stop uses
    // its anchor, not end-of-day, so it weaves among boundaries where it visually
    // sits); the order index keeps stops in their existing order on ties.
    let effectiveKey = TripIdea.effectiveIntraDaySort(stops.map(\.entry))
    var stream: [Row] = stops.enumerated().map { index, stop in
      Row(
        key: effectiveKey[stop.id] ?? stop.entry.schedule.intraDaySort,
        rank: .stop, order: index, item: .stop(stop))
    }
    stream += boundaries
    stream.sort {
      ($0.key, $0.rank.rawValue, $0.order) < ($1.key, $1.rank.rawValue, $1.order)
    }
    return homeBaseRows + stream.map(\.item)
  }

  // MARK: - Per-leg accessors (classifications of the day's chain)

  private func daysStops(_ day: Int) -> [ResolvedStop] {
    itinerary.first(where: { $0.number == day })?.stops ?? []
  }

  /// Directed route segments between consecutive located stops on `day`.
  /// An unlocated stop between two located ones breaks the chain on both sides
  /// (no phantom A→C leg when B has no coords).
  public func legs(forDay day: Int) -> [LegKey] {
    legPairs(in: daysStops(day)).map(\.leg)
  }

  private func legPairs(in stops: [ResolvedStop]) -> [(leg: LegKey, identity: LegIdentity)] {
    zip(stops, stops.dropFirst()).compactMap { a, b in
      guard
        let fromLat = a.content.latitude, let fromLon = a.content.longitude,
        let toLat = b.content.latitude, let toLon = b.content.longitude
      else { return nil }
      return (
        leg: LegKey(fromLat: fromLat, fromLon: fromLon, toLat: toLat, toLon: toLon),
        identity: LegIdentity(from: a.travelEndpointID, to: b.travelEndpointID))
    }
  }

  /// The lodging → first-located-stop leg of the day (`.fromLodging`), whatever
  /// the day's shape: a normal base, the hotel you check into, or the one you
  /// check out of on a changeover.
  public func baseLegs(forDay day: Int) -> [LegKey] {
    baseRouteLeg(forDay: day, stops: daysStops(day), stays: stays(coveringDay: day))
      .map { [$0.leg] } ?? []
  }

  /// `.fromLodging` legs into a stop other than the day's first — the outbound
  /// leg from a mid-day check-in to the next activity. Empty on an ordinary day.
  public func arrivalLegs(forDay day: Int) -> [LegKey] {
    let stops = daysStops(day)
    let firstLocatedID = stops.first(where: isLocated)?.travelEndpointID
    return routeLegs(forDay: day, stops: stops, stays: stays(coveringDay: day))
      .filter { $0.kind == .fromLodging && $0.to.id != firstLocatedID }
      .map(\.leg)
  }

  /// The last-located-stop → lodging leg of the day (`.toLodging`), returning to
  /// the base you spend the night in. Empty on a pure check-out day.
  public func returnLegs(forDay day: Int) -> [LegKey] {
    returnRouteLeg(forDay: day, stops: daysStops(day), stays: stays(coveringDay: day))
      .map { [$0.leg] } ?? []
  }

  /// The direct lodging transfer (`.betweenLodgings`): a hotel→hotel leg drawn
  /// only when the two boundaries are adjacent in the day's timeline. A stop
  /// scheduled between check-out and check-in sits between them as a waypoint, so
  /// no direct leg is emitted.
  public func stayTransferLegs(forDay day: Int) -> [LegKey] {
    routeLegs(forDay: day, stops: daysStops(day), stays: stays(coveringDay: day))
      .filter { $0.kind == .betweenLodgings }
      .map(\.leg)
  }

  private func baseRouteLeg(
    forDay day: Int, stops: [ResolvedStop], stays: [ResolvedStay]
  ) -> RouteLeg? {
    guard let firstLocatedID = stops.first(where: isLocated)?.travelEndpointID else { return nil }
    return routeLegs(forDay: day, stops: stops, stays: stays)
      .first { $0.kind == .fromLodging && $0.to.id == firstLocatedID }
  }

  private func returnRouteLeg(
    forDay day: Int, stops: [ResolvedStop], stays: [ResolvedStay]
  ) -> RouteLeg? {
    guard let lastLocatedID = stops.last(where: isLocated)?.travelEndpointID else { return nil }
    return routeLegs(forDay: day, stops: stops, stays: stays)
      .first { $0.kind == .toLodging && $0.from.id == lastLocatedID }
  }

  // MARK: - Connectors (a chain leg dressed with its ETA and mode)

  private func connector(
    for leg: RouteLeg,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    effectiveModes: [LegKey: TransportMode]
  ) -> TravelConnector {
    let mode = effectiveModes[leg.leg] ?? .walking
    return TravelConnector(
      from: leg.from, to: leg.to, leg: leg.leg, mode: mode,
      travelTime: travelTimes[leg.leg]?[mode], kind: leg.kind)
  }

  func baseConnector(
    forDay day: Int,
    stops: [ResolvedStop],
    stays: [ResolvedStay],
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    effectiveModes: [LegKey: TransportMode]
  ) -> TravelConnector? {
    baseRouteLeg(forDay: day, stops: stops, stays: stays)
      .map { connector(for: $0, travelTimes: travelTimes, effectiveModes: effectiveModes) }
  }

  func returnConnector(
    forDay day: Int,
    stops: [ResolvedStop],
    stays: [ResolvedStay],
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    effectiveModes: [LegKey: TransportMode]
  ) -> TravelConnector? {
    returnRouteLeg(forDay: day, stops: stops, stays: stays)
      .map { connector(for: $0, travelTimes: travelTimes, effectiveModes: effectiveModes) }
  }

  /// The direct lodging transfer on `day`, if the two stay boundaries are
  /// adjacent in the day's timeline. This is the shared transfer-day fact used
  /// by itinerary rows and the Journey/Today projections.
  public func transferConnector(
    forDay day: Int,
    travelTimes: [LegKey: [TransportMode: TravelTime]] = [:],
    effectiveModes: [LegKey: TransportMode] = [:]
  ) -> TravelConnector? {
    let stops = daysStops(day)
    guard let transfer = routeLegs(forDay: day, stops: stops, stays: stays(coveringDay: day))
      .first(where: { $0.kind == .betweenLodgings })
    else { return nil }
    return connector(for: transfer, travelTimes: travelTimes, effectiveModes: effectiveModes)
  }

  /// The lodging handoff on a changeover day, regardless of whether a daytime
  /// stop sits between checkout and check-in. Journey surfaces this fact because
  /// travelers need to anticipate the hotel change; the itinerary uses the
  /// stricter `transferConnector` so it does not draw a misleading direct leg
  /// across an intermediate stop.
  public func lodgingChangeoverConnector(
    forDay day: Int,
    travelTimes: [LegKey: [TransportMode: TravelTime]] = [:],
    effectiveModes: [LegKey: TransportMode] = [:]
  ) -> TravelConnector? {
    guard let changeover = lodgingChangeover(
      forDay: day,
      stays: stays(coveringDay: day))
    else { return nil }
    let mode = effectiveModes[changeover.leg] ?? .walking
    return TravelConnector(
      from: changeover.from,
      to: changeover.to,
      leg: changeover.leg,
      mode: mode,
      travelTime: travelTimes[changeover.leg]?[mode],
      kind: .betweenLodgings)
  }

  private func lodgingChangeover(
    forDay day: Int, stays: [ResolvedStay]
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

  private func locatedEndpoint(for stop: ResolvedStop) -> TravelEndpoint? {
    guard let latitude = stop.content.latitude, let longitude = stop.content.longitude
    else { return nil }
    return TravelEndpoint(
      id: stop.travelEndpointID, title: stop.content.title,
      latitude: latitude, longitude: longitude)
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
    let stops = daysStops(day)
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
