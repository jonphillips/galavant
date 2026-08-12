import Foundation

extension TripPlan {
  // MARK: - Travel-time connectors (docs/trip-canvas.md)

  /// All directed route segments across every day, in itinerary order — the set
  /// the directions client should pre-warm. Only pairs where both endpoints are
  /// located produce a leg.
  public var allLegs: [LegKey] {
    itinerary.flatMap {
      legs(forDay: $0.number)
        + baseLegs(forDay: $0.number)
        + stayTransferLegs(forDay: $0.number)
    }
  }

  /// Directed route segments between consecutive located stops on `day`.
  /// Iterates all stops in order — an unlocated stop between two located ones
  /// breaks the chain on both sides (no phantom A→C leg when B has no coords).
  public func legs(forDay day: Int) -> [LegKey] {
    let stops = itinerary.first(where: { $0.number == day })?.stops ?? []
    return zip(stops, stops.dropFirst()).compactMap { a, b in
      guard
        let fromLat = a.content.latitude, let fromLon = a.content.longitude,
        let toLat = b.content.latitude, let toLon = b.content.longitude
      else { return nil }
      return LegKey(fromLat: fromLat, fromLon: fromLon, toLat: toLat, toLon: toLon)
    }
  }

  /// The located lodging → first-stop leg that is unambiguous in the day
  /// timeline. A normal lodging day uses its one base. On a changeover day, a
  /// first stop before check-in starts from the departing stay; one after it
  /// starts from the arriving stay.
  public func baseLegs(forDay day: Int) -> [LegKey] {
    let stops = itinerary.first(where: { $0.number == day })?.stops ?? []
    guard let route = lodgingToStopRoute(
      forDay: day, stops: stops, stays: stays(coveringDay: day))
    else { return [] }
    return [route.leg]
  }

  /// A direct lodging transfer appears when check-out and check-in are adjacent
  /// in the timeline. Stops before check-out or after check-in do not suppress
  /// it; only a scheduled stop *between* those events does.
  public func stayTransferLegs(forDay day: Int) -> [LegKey] {
    let stops = itinerary.first(where: { $0.number == day })?.stops ?? []
    guard let transfer = stayTransfer(forDay: day, stops: stops, stays: stays(coveringDay: day))
    else { return [] }
    return [transfer.leg]
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
  ) -> (from: TravelEndpoint, to: TravelEndpoint, leg: LegKey)? {
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
        toLat: to.latitude, toLon: to.longitude)
    )
  }

  private func stayTransfer(
    forDay day: Int, stops: [ResolvedStop], stays: [ResolvedStay]
  ) -> (from: TravelEndpoint, to: TravelEndpoint, leg: LegKey)? {
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
        toLat: to.latitude, toLon: to.longitude)
    )
  }

  private func isLocated(_ stop: ResolvedStop) -> Bool {
    stop.content.latitude != nil && stop.content.longitude != nil
  }

  func endpoint(for stop: ResolvedStop) -> TravelEndpoint {
    TravelEndpoint(
      id: "stop-\(stop.id)", title: stop.content.title,
      latitude: stop.content.latitude!, longitude: stop.content.longitude!)
  }

  private func endpoint(for stay: ResolvedStay) -> TravelEndpoint? {
    guard let latitude = stay.content.latitude, let longitude = stay.content.longitude else { return nil }
    return TravelEndpoint(
      id: "stay-\(stay.id)", title: stay.content.title,
      latitude: latitude, longitude: longitude)
  }
}
