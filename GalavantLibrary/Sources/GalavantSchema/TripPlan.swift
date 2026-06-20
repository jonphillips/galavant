import Foundation

/// A `TripIdea` join row resolved to its pool `Idea` — the unit every planning
/// surface renders. Orphans (an idea deleted from the pool, ADR-0007) never form
/// a `ResolvedStop`; they're dropped as the plan is built (read-time
/// reconciliation).
public struct ResolvedStop: Identifiable, Equatable, Sendable {
  public var entry: TripIdea
  public var idea: Idea
  public var id: TripIdea.ID { entry.id }

  public init(entry: TripIdea, idea: Idea) {
    self.entry = entry
    self.idea = idea
  }
}

/// One itinerary day with its resolved stops, pre-ordered (see `TripPlan`).
public struct ResolvedDay: Identifiable, Equatable, Sendable {
  public var number: Int
  public var stops: [ResolvedStop]
  public var id: Int { number }

  public init(number: Int, stops: [ResolvedStop] = []) {
    self.number = number
    self.stops = stops
  }
}

/// One trip's resolved planning read-model: this trip's pulled `TripIdea` entries
/// joined to their pool ideas and partitioned for the planning surfaces (Trip
/// Ideas, Itinerary, Canvas).
///
/// Pure — built from already-fetched arrays, no I/O — so every projection is
/// testable without a database or an `@Observable`. The write side and the raw
/// `[TripIdea]` partitioning live in `TripOperations`; this layer adds the idea
/// join (the `Resolved*` types) that the views consume. The `@Observable` model
/// holds one of these and delegates its read-model questions here.
public struct TripPlan: Equatable, Sendable {
  /// This trip's entries (already scoped to the trip), and the pool lookup that
  /// resolves each entry's idea. `lengthInDays` frames the itinerary.
  public var entries: [TripIdea]
  public var ideasByID: [Idea.ID: Idea]
  public var lengthInDays: Int

  public init(entries: [TripIdea], ideasByID: [Idea.ID: Idea], lengthInDays: Int) {
    self.entries = entries
    self.ideasByID = ideasByID
    self.lengthInDays = lengthInDays
  }

  func resolve(_ entry: TripIdea) -> ResolvedStop? {
    ideasByID[entry.ideaID].map { ResolvedStop(entry: entry, idea: $0) }
  }

  // MARK: - Planning piles (Trip Ideas)

  /// Shortlisted-but-not-yet-scheduled entries in rank order. The Ideas page's
  /// Shortlist section and the Itinerary's Add-Stop sheet draw from this set.
  public var shortlist: [ResolvedStop] {
    entries
      .filter { $0.status == .shortlisted }
      .sorted { $0.shortlistRank < $1.shortlistRank }
      .compactMap(resolve)
  }

  /// Scheduled stops in itinerary order (day, then time of day) — the Ideas
  /// page's Scheduled section.
  public var scheduled: [ResolvedStop] {
    entries
      .filter { $0.status == .scheduled }
      .sorted {
        ($0.dayNumber ?? 0, $0.schedule.intraDaySort, $0.shortlistRank)
          < ($1.dayNumber ?? 0, $1.schedule.intraDaySort, $1.shortlistRank)
      }
      .compactMap(resolve)
  }

  /// The "considering" maybe-pile — pulled but not yet committed.
  public var considering: [ResolvedStop] {
    TripIdea.considering(entries).compactMap(resolve)
  }

  /// Nothing pulled onto the trip at all — drives the Ideas page empty state.
  public var isEmpty: Bool {
    shortlist.isEmpty && scheduled.isEmpty && considering.isEmpty
  }

  // MARK: - Itinerary (scheduled stops laid out by day)

  /// The trip's days 1…N, each with its resolved scheduled stops in order
  /// (orphans dropped). Canvas pins and timeline rows both project from this.
  public var itinerary: [ResolvedDay] {
    TripIdea.itinerary(entries, lengthInDays: lengthInDays).map { day in
      ResolvedDay(number: day.number, stops: day.stops.compactMap(resolve))
    }
  }

  /// True once at least one stop is scheduled — drives the empty state.
  public var hasScheduledStops: Bool { entries.contains { $0.status == .scheduled } }

  /// Scheduled stops not yet placed on a day — the "To Be Scheduled" bucket at
  /// the top of the Itinerary (orphans dropped).
  public var toBeScheduled: [ResolvedStop] {
    TripIdea.toBeScheduled(entries).compactMap(resolve)
  }

  // MARK: - Canvas geometry (pure projections over located stops)

  /// True when at least one scheduled stop carries coordinates to plot.
  public var hasLocatedStops: Bool {
    itinerary.contains { day in
      day.stops.contains { $0.idea.latitude != nil && $0.idea.longitude != nil }
    }
  }

  /// Coordinates of the located scheduled stops to frame the camera on: one day's
  /// when `day` is set, the whole trip's when nil. Ordered as they sit on the
  /// itinerary; feeds the pure `MapFraming.box`.
  public func framingCoordinates(forDay day: Int?) -> [(latitude: Double, longitude: Double)] {
    let days = day.map { d in itinerary.filter { $0.number == d } } ?? itinerary
    return days.flatMap(\.stops).compactMap { resolved in
      guard let lat = resolved.idea.latitude, let lon = resolved.idea.longitude
      else { return nil }
      return (latitude: lat, longitude: lon)
    }
  }

  /// A day's located stops in itinerary order — the route the pins and the
  /// polyline follow. Unlocated stops are dropped (they still list in the
  /// timeline). The view assigns the 1-based sequence number by position.
  public func locatedStops(forDay day: Int) -> [ResolvedStop] {
    (itinerary.first { $0.number == day }?.stops ?? [])
      .filter { $0.idea.latitude != nil && $0.idea.longitude != nil }
  }

  // MARK: - Travel-time connectors (docs/trip-canvas.md)

  /// All directed route segments across every day, in itinerary order — the set
  /// the directions client should pre-warm. Only pairs where both stops are
  /// located produce a leg.
  public var allLegs: [LegKey] {
    itinerary.flatMap { legs(forDay: $0.number) }
  }

  /// Directed route segments between consecutive located stops on `day`.
  /// Iterates all stops in order — an unlocated stop between two located ones
  /// breaks the chain on both sides (no phantom A→C leg when B has no coords).
  public func legs(forDay day: Int) -> [LegKey] {
    let stops = itinerary.first(where: { $0.number == day })?.stops ?? []
    return zip(stops, stops.dropFirst()).compactMap { a, b in
      guard
        let fromLat = a.idea.latitude, let fromLon = a.idea.longitude,
        let toLat = b.idea.latitude, let toLon = b.idea.longitude
      else { return nil }
      return LegKey(fromLat: fromLat, fromLon: fromLon, toLat: toLat, toLon: toLon)
    }
  }

  /// The interleaved stop + connector rows for one day's timeline. A connector
  /// is inserted between consecutive located stops. A `.nowMarker` divider is
  /// inserted at the current moment when `now` and `tripStartDate` are supplied
  /// and today falls on this day; it never appears for undated trips.
  public func itineraryItems(
    forDay day: Int,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    effectiveModes: [LegKey: TransportMode],
    now: Date? = nil,
    tripStartDate: Date? = nil
  ) -> [ItineraryItem] {
    guard let resolvedDay = itinerary.first(where: { $0.number == day }) else { return [] }
    let stops = resolvedDay.stops
    guard !stops.isEmpty else { return [] }

    // Index in `stops` before which to insert the now marker, or `stops.count`
    // to place it after all stops (every stop is past). Nil = don't show marker.
    let markerAt: Int? = {
      guard let now, let tripStartDate else { return nil }
      let cal = Calendar.current
      guard
        let dayStart = cal.date(byAdding: .day, value: day - 1, to: tripStartDate),
        cal.isDate(now, inSameDayAs: dayStart)
      else { return nil }
      return stops.firstIndex(where: { stop in
        guard let d = nominalDate(entry: stop.entry, dayStart: dayStart, calendar: cal)
        else { return false }
        return d > now
      }) ?? stops.count
    }()

    var items: [ItineraryItem] = []
    var markerInserted = false
    for (i, stop) in stops.enumerated() {
      if let at = markerAt, i == at, !markerInserted {
        items.append(.nowMarker)
        markerInserted = true
      }
      items.append(.stop(stop))
      guard i < stops.count - 1 else { continue }
      let next = stops[i + 1]
      guard
        let fromLat = stop.idea.latitude, let fromLon = stop.idea.longitude,
        let toLat = next.idea.latitude, let toLon = next.idea.longitude
      else { continue }
      let key = LegKey(fromLat: fromLat, fromLon: fromLon, toLat: toLat, toLon: toLon)
      let mode = effectiveModes[key] ?? .walking
      let tt = travelTimes[key]?[mode]
      items.append(.connector(TravelConnector(
        fromStopID: stop.id, toStopID: next.id, leg: key, mode: mode, travelTime: tt)))
    }
    // Marker after the last stop when every stop is past.
    if let at = markerAt, at == stops.count, !markerInserted {
      items.append(.nowMarker)
    }
    return items
  }

  /// Resolve the idea for an itinerary stop by its `TripIdea` ID — used by the
  /// view to get coordinates for the Open in Maps handoff on a connector row.
  public func idea(forStopID id: TripIdea.ID) -> Idea? {
    guard let entry = entries.first(where: { $0.id == id }) else { return nil }
    return ideasByID[entry.ideaID]
  }

  // MARK: - Temporal helpers

  /// The nominal start time of a scheduled stop on a given day — the moment
  /// it's considered "upcoming." Returns nil for unscheduled stops.
  /// - `.timed` → parsed start hour:minute
  /// - `.daypart` → `sortHour` (the representative hour for ordering)
  /// - `.day` → end of day (23:59), so a bare-day stop is only "past" after midnight
  private func nominalDate(entry: TripIdea, dayStart: Date, calendar: Calendar) -> Date? {
    switch entry.schedule {
    case .unscheduled:
      return nil
    case .day:
      return calendar.date(bySettingHour: 23, minute: 59, second: 59, of: dayStart)
    case .daypart(_, let part):
      return calendar.date(bySettingHour: part.sortHour, minute: 0, second: 0, of: dayStart)
    case .timed(_, let start, _):
      guard let mins = Schedule.minutes(from: start) else { return nil }
      return calendar.date(byAdding: .minute, value: mins, to: calendar.startOfDay(for: dayStart))
    }
  }
}
