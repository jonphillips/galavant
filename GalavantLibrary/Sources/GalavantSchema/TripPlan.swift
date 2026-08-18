import Foundation
import IssueReporting

/// What a stop *is* — the pool idea it was pulled from, or an inline freeform
/// entry with no idea (ADR-0010, amended by ADR-0042). Both cases can carry
/// coordinates for pins and legs; freeform coordinates come from the inline stop
/// columns and remain optional.
public enum StopContent: Equatable, Sendable {
  case idea(Idea)
  case freeform(title: String, note: String?, latitude: Double?, longitude: Double?)

  /// Display title for the stop row.
  public var title: String {
    switch self {
    case let .idea(idea): idea.name
    case let .freeform(title, _, _, _): title
    }
  }

  /// The pool idea, or nil for freeform stops.
  public var idea: Idea? {
    if case let .idea(idea) = self { idea } else { nil }
  }

  /// Latitude for canvas/leg geometry.
  public var latitude: Double? {
    switch self {
    case let .idea(idea): idea.latitude
    case let .freeform(_, _, latitude, _): latitude
    }
  }

  /// Longitude for canvas/leg geometry.
  public var longitude: Double? {
    switch self {
    case let .idea(idea): idea.longitude
    case let .freeform(_, _, _, longitude): longitude
    }
  }
}

/// A `TripIdea` join row resolved to its content — the unit every planning
/// surface renders. Orphans (an idea deleted from the pool, ADR-0007) and
/// malformed freeform entries (no title) are dropped as the plan is built.
public struct ResolvedStop: Identifiable, Equatable, Sendable {
  public var entry: TripIdea
  public var content: StopContent
  public var id: TripIdea.ID { entry.id }

  /// The pool idea for idea-backed stops; nil for freeform stops.
  public var idea: Idea? { content.idea }

  public init(entry: TripIdea, content: StopContent) {
    self.entry = entry
    self.content = content
  }
}

/// A `TripStay` resolved to its content (ADR-0011) — the home-base unit the
/// itinerary chip and the canvas base pin render. Reuses `StopContent`: a stay
/// resolves to `.idea` when its pool hotel is found, `.freeform` when it carries
/// an inline title. Orphans (pool hotel deleted) and malformed entries (no title)
/// drop on read, exactly as a stop does.
public struct ResolvedStay: Identifiable, Equatable, Sendable {
  public var stay: TripStay
  public var content: StopContent
  public var id: TripStay.ID { stay.id }

  /// The pool hotel for idea-backed stays; nil for freeform stays.
  public var idea: Idea? { content.idea }

  public init(stay: TripStay, content: StopContent) {
    self.stay = stay
    self.content = content
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

/// A recoverable alternatives ring resolved for presentation. `members` remain
/// in canonical cycle order; `activeIndex` names the effective member rather
/// than imposing an active-first presentation order (ADR-0035).
public struct ResolvedAlternativeRing: Equatable, Sendable {
  public var groupID: UUID
  public var label: String?
  public var members: [ResolvedStop]
  public var activeIndex: Int

  public var activeMember: ResolvedStop { members[activeIndex] }
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
  /// This trip's accommodations (already scoped to the trip), resolved against the
  /// same `ideasByID` pool lookup as stops (ADR-0011). Defaults empty so existing
  /// call sites that don't pass stays keep compiling.
  public var tripStays: [TripStay]
  /// This trip's per-day region assignments (already scoped to the trip), resolved
  /// against `regionsByID` (ADR-0012). Defaults empty so existing call sites keep
  /// compiling.
  public var dayRegions: [TripDayRegion]
  /// The pool of map regions a day assignment can resolve to. Defaults empty.
  public var regionsByID: [MapRegion.ID: MapRegion]
  /// Calendar-authored obligations with no place/stop match. They are already
  /// trip-scoped shared domain state and weave into the itinerary by their
  /// projected trip day and civil time.
  public var calendarConstraints: [CalendarTripConstraint]
  /// Optional labels for ADR-0035 alternatives rings, joined by group ID during
  /// projection. A missing row intentionally produces no label.
  public var alternativeGroups: [TripAlternativeGroup]

  public init(
    entries: [TripIdea],
    ideasByID: [Idea.ID: Idea],
    lengthInDays: Int,
    tripStays: [TripStay] = [],
    dayRegions: [TripDayRegion] = [],
    regionsByID: [MapRegion.ID: MapRegion] = [:],
    calendarConstraints: [CalendarTripConstraint] = [],
    alternativeGroups: [TripAlternativeGroup] = []
  ) {
    self.entries = entries
    self.ideasByID = ideasByID
    self.lengthInDays = lengthInDays
    self.tripStays = tripStays
    self.dayRegions = dayRegions
    self.regionsByID = regionsByID
    self.calendarConstraints = calendarConstraints
    self.alternativeGroups = alternativeGroups
    // A stop must carry either an `ideaID` or a non-empty inline title (ADR-0010);
    // one that carries neither is a corrupt row we cannot place. Reported once per
    // read-model build (not once per projection, which now resolves entries several
    // times) so the invariant still surfaces without duplicate noise. Orphans — an
    // `ideaID` whose pool idea was deleted — are legitimate drops and not reported.
    for entry in entries where entry.ideaID == nil && (entry.inlineTitle?.isEmpty ?? true) {
      reportIssue("TripIdea \(entry.id) has neither ideaID nor inlineTitle — dropping")
    }
  }

  func resolve(_ entry: TripIdea) -> ResolvedStop? {
    if let ideaID = entry.ideaID {
      guard let idea = ideasByID[ideaID] else { return nil }  // orphan — drop
      return ResolvedStop(entry: entry, content: .idea(idea))
    } else if let title = entry.inlineTitle, !title.isEmpty {
      return ResolvedStop(
        entry: entry,
        content: .freeform(
          title: title,
          note: entry.inlineNote,
          latitude: entry.inlineLatitude,
          longitude: entry.inlineLongitude))
    } else {
      return nil
    }
  }

  /// The alternatives rings after orphan/malformed members are dropped. This is
  /// deliberately non-mutating: a later explicit ring operation persists the
  /// effective winner and clears a one-member remnant.
  private var resolvedAlternativeRings: [UUID: ResolvedAlternativeRing] {
    alternativeRings(
      in: entries.compactMap(resolve),
      labelsByGroupID: Dictionary(
        alternativeGroups.compactMap { group in
          TripAlternativeGroup.normalizedLabel(group.label).map { (group.id, $0) }
        },
        uniquingKeysWith: { first, _ in first }))
  }

  private func alternativeRings(
    in resolved: [ResolvedStop],
    labelsByGroupID: [UUID: String] = [:]
  ) -> [UUID: ResolvedAlternativeRing] {
    let grouped = Dictionary(grouping: resolved) { $0.entry.alternativeGroupID }
    return Dictionary(uniqueKeysWithValues: grouped.compactMap { groupID, members in
      guard let groupID else { return nil }
      let orderedEntries = TripIdea.canonicalAlternativeOrder(members.map(\.entry))
      let membersByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
      let ordered = orderedEntries.compactMap { membersByID[$0.id] }
      guard ordered.count > 1 else { return nil }
      let activeIndex = ordered.firstIndex { $0.entry.isActive } ?? ordered.startIndex
      return (groupID, ResolvedAlternativeRing(
        groupID: groupID,
        label: labelsByGroupID[groupID],
        members: ordered,
        activeIndex: activeIndex))
    })
  }

  /// Resolve one visible member for every ring. Filtering after resolution keeps
  /// an orphaned stored-active member from hiding the rest of a valid slot.
  private var effectiveResolvedStops: [ResolvedStop] {
    let resolved = entries.compactMap(resolve)
    let winners = Dictionary(uniqueKeysWithValues: alternativeRings(in: resolved).map {
      ($0.key, $0.value.activeMember.id)
    })
    return resolved.filter { stop in
      guard let groupID = stop.entry.alternativeGroupID else { return true }
      guard let winnerID = winners[groupID] else { return true }
      return stop.id == winnerID
    }
  }

  /// The ring containing `stopID`, when at least two members resolve. A lone
  /// surviving member intentionally presents as an ordinary stop until the next
  /// ring write repairs its stored remnant.
  public func alternatives(forStop stopID: TripIdea.ID) -> ResolvedAlternativeRing? {
    guard let groupID = entries.first(where: { $0.id == stopID })?.alternativeGroupID else {
      return nil
    }
    return resolvedAlternativeRings[groupID]
  }

  /// Resolve a stay to its content (ADR-0011) — the same total mapping `resolve`
  /// performs for a stop. Orphan (pool hotel deleted) and malformed (no title)
  /// stays drop.
  func resolveStay(_ stay: TripStay) -> ResolvedStay? {
    if let ideaID = stay.ideaID {
      guard let idea = ideasByID[ideaID] else { return nil }  // orphan — drop
      return ResolvedStay(stay: stay, content: .idea(idea))
    } else if let title = stay.inlineTitle, !title.isEmpty {
      return ResolvedStay(
        stay: stay,
        content: .freeform(title: title, note: stay.inlineNote, latitude: nil, longitude: nil))
    } else {
      reportIssue("TripStay \(stay.id) has neither ideaID nor inlineTitle — dropping")
      return nil
    }
  }

  // MARK: - Planning piles (Trip Ideas)

  /// Shortlisted-but-not-yet-scheduled entries in rank order. The Ideas page's
  /// Shortlist section and the Itinerary's Add-Stop sheet draw from this set.
  /// A lodging idea that has become a stay is no longer actionable here; the
  /// stay's itinerary row is its trip-scoped home instead.
  public var shortlist: [ResolvedStop] {
    let stayedIdeaIDs = Set(tripStays.compactMap(\.ideaID))
    return entries
      .filter { entry in
        guard entry.status == .shortlisted else { return false }
        guard let ideaID = entry.ideaID, stayedIdeaIDs.contains(ideaID) else { return true }
        return ideasByID[ideaID]?.kind != .stay
      }
      .sorted { $0.shortlistRank < $1.shortlistRank }
      .compactMap(resolve)
  }

  /// Scheduled stops in itinerary order (day, then the ADR-0033 intra-day order —
  /// timed by clock, Anytime interleaved by anchor+`dayRank`) — the Ideas page's
  /// Scheduled section. Grouped by day so each day's Anytime stops anchor within
  /// their own day, matching the itinerary.
  public var scheduled: [ResolvedStop] {
    let byDay = Dictionary(grouping: effectiveResolvedStops.filter { $0.entry.status == .scheduled }) {
      $0.entry.dayNumber ?? 0
    }
    return byDay.keys.sorted()
      .flatMap { orderedResolvedStops(byDay[$0] ?? []) }
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
    let resolved = effectiveResolvedStops
    let stopsByID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
    return TripIdea.itinerary(resolved.map(\.entry), lengthInDays: lengthInDays).map { day in
      ResolvedDay(number: day.number, stops: day.stops.compactMap { stopsByID[$0.id] })
    }
  }

  /// True once at least one stop is scheduled — drives the empty state.
  public var hasScheduledStops: Bool {
    effectiveResolvedStops.contains { $0.entry.status == .scheduled }
  }

  /// Scheduled stops not yet placed on a day — the "To Be Scheduled" bucket at
  /// the top of the Itinerary (orphans dropped).
  public var toBeScheduled: [ResolvedStop] {
    let resolved = effectiveResolvedStops
    let stopsByID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
    return TripIdea.toBeScheduled(resolved.map(\.entry)).compactMap { stopsByID[$0.id] }
  }

  private func orderedResolvedStops(_ stops: [ResolvedStop]) -> [ResolvedStop] {
    let stopsByID = Dictionary(uniqueKeysWithValues: stops.map { ($0.id, $0) })
    return TripIdea.orderedDayStops(stops.map(\.entry)).compactMap { stopsByID[$0.id] }
  }

  // MARK: - Stays (accommodations, ADR-0011)

  /// This trip's resolved accommodations in span order (check-in day, then
  /// check-out day, then check-in time), orphans/malformed dropped. The Itinerary
  /// home-base chips and the Canvas base pins both project from this.
  public var stays: [ResolvedStay] {
    tripStays
      .sorted {
        ($0.checkInDay, $0.checkOutDay, $0.checkInSortMinutes)
          < ($1.checkInDay, $1.checkOutDay, $1.checkInSortMinutes)
      }
      .compactMap(resolveStay)
  }

  /// True once the trip has at least one (resolvable) stay.
  public var hasStays: Bool { !stays.isEmpty }

  /// The resolved stays whose span covers `day` (check-in through check-out,
  /// inclusive) — the home-base chip on each covered day's section header and the
  /// per-day canvas base pins draw from this. Already in span order.
  public func stays(coveringDay day: Int) -> [ResolvedStay] {
    stays.filter { $0.stay.covers(day: day) }
  }

  /// Stays flagged as overlapping another stay (sharing a night) — advisory only,
  /// surfaced like the gap-conflict family, never blocked (ADR-0011 §6). Computed
  /// over the *resolvable* stays so a dropped orphan never raises a phantom flag.
  public var overlappingStayIDs: Set<TripStay.ID> {
    TripStay.overlapping(stays.map(\.stay))
  }

  /// The **located** stays the canvas draws as off-sequence base pins for the
  /// current lens (ADR-0011): the stays covering `day`, or every stay on the "All"
  /// lens (`day == nil`). Distinct per stay (a span covering several days in the
  /// "All" lens still draws one base pin). Freeform/unlocated stays drop — they
  /// have no coordinate, so they fall out of the canvas for free.
  public func baseStays(forDay day: Int?) -> [ResolvedStay] {
    let candidates = day.map { stays(coveringDay: $0) } ?? stays
    return candidates.filter { $0.content.latitude != nil && $0.content.longitude != nil }
  }

  /// Coordinates of the located base stays for `day` — the optional camera-framing
  /// fold (ADR-0011): combine with `framingCoordinates(forDay:)` so a day's base
  /// pin stays in frame even when its stops sit elsewhere. Kept separate so the
  /// point-stop `framingCoordinates` stays untouched.
  public func baseCoordinates(forDay day: Int?) -> [(latitude: Double, longitude: Double)] {
    baseStays(forDay: day).compactMap { resolved in
      guard let lat = resolved.content.latitude, let lon = resolved.content.longitude
      else { return nil }
      return (latitude: lat, longitude: lon)
    }
  }

  /// The chronological path through the trip's located lodging stays. This is
  /// deliberately separate from the day-stop routes: it is shown only on the
  /// canvas's All lens as the overnight movement story, never as numbered stops.
  public var lodgingPathCoordinates: [(latitude: Double, longitude: Double)] { baseCoordinates(forDay: nil) }

  // MARK: - Per-day region (ADR-0012)

  /// The `MapRegion` assigned to `day`, if any — resolved from the day's
  /// `TripDayRegion` assignment against `regionsByID`. A deleted region (orphan)
  /// resolves to nil and drops out, the same reconciliation `TripRegion` uses. The
  /// canvas frames an *empty* day (no located stops) to this region; the day-header
  /// chip labels the day with it.
  public func region(forDay day: Int) -> MapRegion? {
    dayRegions
      .first { $0.dayNumber == day }
      .flatMap { regionsByID[$0.regionID] }
  }

  // MARK: - Canvas geometry (pure projections over located stops)

  /// True when at least one scheduled stop carries coordinates to plot.
  public var hasLocatedStops: Bool {
    itinerary.contains { day in
      day.stops.contains { $0.content.latitude != nil && $0.content.longitude != nil }
    }
  }

  /// Coordinates of the located scheduled stops to frame the camera on: one day's
  /// when `day` is set, the whole trip's when nil. Ordered as they sit on the
  /// itinerary; feeds the pure `MapFraming.box`.
  public func framingCoordinates(forDay day: Int?) -> [(latitude: Double, longitude: Double)] {
    let days = day.map { d in itinerary.filter { $0.number == d } } ?? itinerary
    return days.flatMap(\.stops).compactMap { resolved in
      guard let lat = resolved.content.latitude, let lon = resolved.content.longitude
      else { return nil }
      return (latitude: lat, longitude: lon)
    }
  }

  /// A day's located stops in itinerary order — the route the pins and the
  /// polyline follow. Unlocated stops are dropped (they still list in the
  /// timeline). The view assigns the 1-based sequence number by position.
  public func locatedStops(forDay day: Int) -> [ResolvedStop] {
    (itinerary.first { $0.number == day }?.stops ?? [])
      .filter { $0.content.latitude != nil && $0.content.longitude != nil }
  }

  /// The 1-based map-pin sequence number for each located stop on `day`, keyed by
  /// stop ID — the exact numbering the canvas pins wear (`locatedStops(forDay:)`
  /// order). Unlocated/freeform stops are absent (they carry no pin), so a timeline
  /// row looks itself up here and shows a number only when it has a matching pin.
  public func locatedSequenceNumbers(forDay day: Int) -> [TripIdea.ID: Int] {
    var result: [TripIdea.ID: Int] = [:]
    for (index, stop) in locatedStops(forDay: day).enumerated() {
      result[stop.id] = index + 1
    }
    return result
  }

  /// The interleaved rows for one day's timeline: stops, travel-time connectors
  /// between consecutive located stops, the optional `.nowMarker`, and — when
  /// `stays` is supplied (ADR-0011) — the `.checkIn` / `.checkOut` boundary rows
  /// for any stay arriving or leaving on this day, woven in by their (optional)
  /// time. A check row sorts by `checkInSortMinutes` / `checkOutSortMinutes`
  /// (default evening / morning); a check-out at equal time sorts *before* a stop,
  /// a check-in *after*, so an untimed day reads check-out → stops → check-in. The
  /// now-marker continues to key off point stops only (ADR-0011); a stay's middle
  /// days carry no row here — they show only the home-base chip in the header.
  // The timeline's one-pass weave intentionally owns stop, boundary, now-marker,
  // and lodging-direction ordering so both itinerary projections agree.
  // swiftlint:disable:next function_body_length
  public func itineraryItems(
    forDay day: Int,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    effectiveModes: [LegKey: TransportMode],
    now: Date? = nil,
    tripStartDate: Date? = nil,
    stays: [ResolvedStay] = []
  ) -> [ItineraryItem] {
    let stops = itinerary.first(where: { $0.number == day })?.stops ?? []

    // The day's check boundary rows (a stay leaving and/or a stay arriving today).
    // Rank orders ties against a same-minute stop: check-out (0) before, check-in
    // (2) after, stops sit at rank 1. A *middle* day a stay covers (neither
    // boundary) instead gets a persistent home-base row, pinned to the top.
    enum TieBreak: Int {
      case allDayContext
      case checkOut
      case calendarConstraint
      case stop
      case checkIn
    }
    struct Boundary { let key: Int; let rank: TieBreak; let item: ItineraryItem }
    var boundaries: [Boundary] = []
    var homeBaseRows: [ItineraryItem] = []
    for resolved in stays {
      let stay = resolved.stay
      if stay.checkOutDay == day {
        boundaries.append(Boundary(
          key: stay.checkOutSortMinutes, rank: .checkOut, item: .checkOut(resolved)))
      }
      if stay.checkInDay == day {
        boundaries.append(Boundary(
          key: stay.checkInSortMinutes, rank: .checkIn, item: .checkIn(resolved)))
      }
      if stay.checkInDay != day, stay.checkOutDay != day {
        homeBaseRows.append(.homeBase(resolved))  // covered middle day
      }
    }
    let constraints = calendarConstraints.filter { $0.dayNumber == day }
    boundaries += constraints.map { constraint in
      Boundary(
        key: constraint.startTime.map { Schedule.minutes(from: $0) ?? constraint.schedule.intraDaySort } ?? 0,
        rank: constraint.startTime == nil ? .allDayContext : .calendarConstraint,
        item: .calendarConstraint(constraint))
    }

    // A day with no stops, constraints, stay boundaries, or home base has no timeline.
    guard !stops.isEmpty || !boundaries.isEmpty || !homeBaseRows.isEmpty else { return [] }

    let markerAt = nowMarkerIndex(
      in: stops, day: day, now: now, tripStartDate: tripStartDate)

    // One ordered stream of stops + boundaries. Stops carry their *effective*
    // intra-day key at rank 1 (ADR-0033: an Anytime stop uses its anchor, not
    // end-of-day, so it weaves among boundaries where it visually sits); a stable
    // sort keeps stops in their existing order on ties.
    let effectiveKey = TripIdea.effectiveIntraDaySort(stops.map(\.entry))
    enum Slot { case stop(Int); case boundary(ItineraryItem) }
    var stream: [(key: Int, rank: TieBreak, slot: Slot)] =
      stops.enumerated().map { (i, stop) in
        (effectiveKey[stop.id] ?? stop.entry.schedule.intraDaySort, .stop, .stop(i))
      }
    stream += boundaries.map { ($0.key, $0.rank, .boundary($0.item)) }
    stream.sort {
      ($0.key, $0.rank.rawValue) < ($1.key, $1.rank.rawValue)
    }
    let lastStopStreamIndex = stream.lastIndex { entry in
      if case .stop = entry.slot { return true }
      return false
    }

    // Home-base rows lead the day (the persistent "you're staying here" anchor).
    var items: [ItineraryItem] = homeBaseRows
    let baseConnector = baseConnector(
      forDay: day, stops: stops, stays: stays,
      travelTimes: travelTimes, effectiveModes: effectiveModes)
    let stayTransferConnector = stayTransferConnector(
      forDay: day, stops: stops, stays: stays,
      travelTimes: travelTimes, effectiveModes: effectiveModes)
    let returnConnector = returnConnector(
      forDay: day, stops: stops, stays: stays,
      travelTimes: travelTimes, effectiveModes: effectiveModes)
    var markerInserted = false
    var baseConnectorInserted = false
    var stayTransferInserted = false
    for (streamIndex, entry) in stream.enumerated() {
      switch entry.slot {
      case let .boundary(item):
        items.append(item)
        if case let .checkOut(stay) = item,
          !stayTransferInserted,
          stayTransferConnector?.from.id == "stay-\(stay.id)",
          let stayTransferConnector {
          items.append(.connector(stayTransferConnector))
          stayTransferInserted = true
        }
      case let .stop(i):
        if let at = markerAt, i == at, !markerInserted {
          items.append(.nowMarker)
          markerInserted = true
        }
        let stop = stops[i]
        if !baseConnectorInserted, baseConnector?.to.id == "stop-\(stop.id)",
          let baseConnector {
          items.append(.connector(baseConnector))
          baseConnectorInserted = true
        }
        items.append(.stop(stop))
        if streamIndex == lastStopStreamIndex, let returnConnector {
          items.append(.connector(returnConnector))
        }
        // A connector trails a stop when the next route stop (i+1) is also located.
        guard i < stops.count - 1 else { continue }
        let next = stops[i + 1]
        guard
          let fromLat = stop.content.latitude, let fromLon = stop.content.longitude,
          let toLat = next.content.latitude, let toLon = next.content.longitude
        else { continue }
        let key = LegKey(fromLat: fromLat, fromLon: fromLon, toLat: toLat, toLon: toLon)
        let mode = effectiveModes[key] ?? .walking
        let tt = travelTimes[key]?[mode]
        items.append(.connector(TravelConnector(
          from: endpoint(for: stop), to: endpoint(for: next),
          leg: key, mode: mode, travelTime: tt)))
      }
    }
    // Marker after the last stop when every stop is past.
    if let at = markerAt, at == stops.count, !markerInserted {
      items.append(.nowMarker)
    }
    return items
  }

  /// Index in `stops` before which the "now" marker belongs, or `stops.count` to
  /// place it after all stops (every stop is past). Nil = no marker (not today, or
  /// no clock supplied). Factored out of `itineraryItems` to keep that body lean.
  private func nowMarkerIndex(
    in stops: [ResolvedStop], day: Int, now: Date?, tripStartDate: Date?
  ) -> Int? {
    guard let now, let tripStartDate, !stops.isEmpty else { return nil }
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
  }

  /// Resolve the idea for an itinerary stop by its `TripIdea` ID — used by the
  /// view to get coordinates for the Open in Maps handoff on a connector row.
  /// Returns nil for freeform stops (they produce no connectors, so this is
  /// defensive only).
  public func idea(forStopID id: TripIdea.ID) -> Idea? {
    guard let entry = entries.first(where: { $0.id == id }),
          let ideaID = entry.ideaID
    else { return nil }
    return ideasByID[ideaID]
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
