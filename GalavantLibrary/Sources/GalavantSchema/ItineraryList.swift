import Foundation

public struct ItineraryStopFacts: Equatable, Sendable {
  public var ring: ResolvedAlternativeRing?
  public var canMoveEarlier = false
  public var canMoveLater = false

  public init(ring: ResolvedAlternativeRing? = nil, canMoveEarlier: Bool = false, canMoveLater: Bool = false) {
    self.ring = ring
    self.canMoveEarlier = canMoveEarlier
    self.canMoveLater = canMoveLater
  }
}

public struct ItineraryList: Equatable, Sendable {
  public struct Day: Identifiable, Equatable, Sendable {
    public var number: Int
    public var stops: [ResolvedStop]
    public var items: [ItineraryItem]
    public var sequence: [TripIdea.ID: Int]
    public var id: Int { number }

    public init(number: Int, stops: [ResolvedStop], items: [ItineraryItem], sequence: [TripIdea.ID: Int]) {
      self.number = number
      self.stops = stops
      self.items = items
      self.sequence = sequence
    }
  }

  public var toBeScheduled: [ResolvedStop]
  public var days: [Day]
  public var overlappingStayIDs: Set<TripStay.ID>
  public var showsSketchPrompt: Bool
  private var factsByStopID: [TripIdea.ID: ItineraryStopFacts]

  public init(
    toBeScheduled: [ResolvedStop], days: [Day], overlappingStayIDs: Set<TripStay.ID>,
    showsSketchPrompt: Bool, factsByStopID: [TripIdea.ID: ItineraryStopFacts]
  ) {
    self.toBeScheduled = toBeScheduled
    self.days = days
    self.overlappingStayIDs = overlappingStayIDs
    self.showsSketchPrompt = showsSketchPrompt
    self.factsByStopID = factsByStopID
  }

  public func facts(forStop id: TripIdea.ID) -> ItineraryStopFacts {
    factsByStopID[id] ?? ItineraryStopFacts()
  }
}

extension TripPlan {
  /// Derive every itinerary row input in one pass over the shared plan values.
  public func itineraryList(
    focusedDay: Int?,
    overrides: [LegIdentity: TransportMode],
    mainMode: TransportMode?,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    autoSwitchThreshold: TimeInterval,
    now: Date?,
    tripStartDate: Date?
  ) -> ItineraryList {
    itineraryList(
      focusedDay: focusedDay, overrides: overrides, mainMode: mainMode,
      travelTimes: travelTimes, autoSwitchThreshold: autoSwitchThreshold,
      now: now, tripStartDate: tripStartDate,
      resolvedStops: { effectiveResolvedStops },
      resolvedStays: { stays },
      rings: { resolvedRingsByStop })
  }

  package func itineraryList(
    focusedDay: Int?,
    overrides: [LegIdentity: TransportMode],
    mainMode: TransportMode?,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    autoSwitchThreshold: TimeInterval,
    now: Date?,
    tripStartDate: Date?,
    resolvedStops deriveStops: () -> [ResolvedStop],
    resolvedStays deriveStays: () -> [ResolvedStay],
    rings deriveRings: () -> [TripIdea.ID: ResolvedAlternativeRing]
  ) -> ItineraryList {
    let resolvedStops = deriveStops()
    let resolvedStays = deriveStays()
    let rings = deriveRings()
    let stopsByID = Dictionary(uniqueKeysWithValues: resolvedStops.map { ($0.id, $0) })
    let allDays = TripIdea.itinerary(resolvedStops.map(\.entry), lengthInDays: lengthInDays).map { day in
      ResolvedDay(number: day.number, stops: day.stops.compactMap { stopsByID[$0.id] })
    }
    let scheduled = TripIdea.toBeScheduled(resolvedStops.map(\.entry)).compactMap { stopsByID[$0.id] }
    let ringFacts = rings
    let overlappingStayIDs = TripStay.overlapping(resolvedStays.map(\.stay))

    let pairs = allLegPairs(itinerary: { allDays }, stays: { resolvedStays })
    let modes = Self.legModes(
      pairs: pairs, overrides: overrides, mainMode: mainMode,
      travelTimes: travelTimes, autoSwitchThreshold: autoSwitchThreshold)

    let visibleDays: [ResolvedDay]
    if let focusedDay {
      visibleDays = [allDays.first { $0.number == focusedDay } ?? ResolvedDay(number: focusedDay)]
    } else {
      visibleDays = allDays
    }
    let days = visibleDays.map { day in
      let dayStays = resolvedStays.filter { $0.stay.covers(day: day.number) }
      let items = itineraryItems(
        forDay: day.number, stops: day.stops,
        travelTimes: travelTimes, effectiveModes: modes,
        now: now, tripStartDate: tripStartDate, stays: dayStays)
      return ItineraryList.Day(
        number: day.number, stops: day.stops, items: items,
        sequence: Self.locatedSequenceNumbers(for: day.stops))
    }

    var facts: [TripIdea.ID: ItineraryStopFacts] = [:]
    for day in allDays {
      for (index, stop) in day.stops.enumerated() {
        facts[stop.id] = ItineraryStopFacts(
          ring: ringFacts[stop.id],
          canMoveEarlier: Self.moveTarget(from: index, in: day.stops, earlier: true) != nil,
          canMoveLater: Self.moveTarget(from: index, in: day.stops, earlier: false) != nil)
      }
    }
    // Rings include unscheduled entries and non-winning members too.
    for (id, ring) in ringFacts where facts[id] == nil {
      facts[id] = ItineraryStopFacts(ring: ring)
    }

    return ItineraryList(
      toBeScheduled: scheduled, days: days,
      overlappingStayIDs: overlappingStayIDs,
      showsSketchPrompt: !resolvedStops.contains { $0.entry.status == .scheduled } && dayRegions.isEmpty,
      factsByStopID: facts)
  }

  package var resolvedRingsByStop: [TripIdea.ID: ResolvedAlternativeRing] {
    Dictionary(resolvedAlternativeRings.values.flatMap { ring in
      ring.members.map { ($0.id, ring) }
    }, uniquingKeysWith: { first, _ in first })
  }

  public static func reorderedIDs(
    moving stop: ResolvedStop, in orderedStops: [ResolvedStop], earlier: Bool
  ) -> [TripIdea.ID]? {
    guard let from = orderedStops.firstIndex(where: { $0.id == stop.id }),
      let to = moveTarget(from: from, in: orderedStops, earlier: earlier)
    else { return nil }
    var ids = orderedStops.map(\.id)
    ids.remove(at: from)
    ids.insert(stop.id, at: to)
    return ids
  }

  public static func moveTarget(from index: Int, in stops: [ResolvedStop], earlier: Bool) -> Int? {
    guard stops.indices.contains(index), case .day = stops[index].entry.schedule else { return nil }
    let target = earlier ? index - 1 : index + 1
    return stops.indices.contains(target) ? target : nil
  }

  static func locatedSequenceNumbers(for stops: [ResolvedStop]) -> [TripIdea.ID: Int] {
    var result: [TripIdea.ID: Int] = [:]
    for (index, stop) in stops.filter({ $0.content.latitude != nil && $0.content.longitude != nil }).enumerated() {
      result[stop.id] = index + 1
    }
    return result
  }
}
