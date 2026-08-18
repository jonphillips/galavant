import Foundation
import GalavantSchema
import Testing

/// `TripPlan` is the pure read-model that joins this trip's `TripIdea` entries to
/// their pool ideas and partitions them for the planning surfaces. These tests
/// exercise it as a plain value — no database, no `@Observable` — which is the
/// whole point of pulling the join out of `TripPlanningModel`.
@Suite struct TripPlanTests {
  // A located idea by default, so the canvas-geometry projections have something
  // to plot; pass nil coords for the unlocated cases.
  func idea(
    _ id: Idea.ID, name: String = "", lat: Double? = 1, lon: Double? = 1
  ) -> Idea {
    Idea(id: id, name: name, latitude: lat, longitude: lon)
  }

  func entry(
    idea: Idea.ID,
    status: TripIdeaStatus,
    rank: Int = 0,
    dayRank: Double? = nil,
    schedule: Schedule = .unscheduled
  ) -> TripIdea {
    var e = TripIdea(
      id: UUID(), tripID: UUID(), ideaID: idea, status: status,
      shortlistRank: rank, dayRank: dayRank ?? Double(rank))
    e.apply(schedule)
    return e
  }

  func freeformEntry(
    title: String,
    note: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    rank: Int = 0,
    dayRank: Double? = nil,
    schedule: Schedule = .unscheduled
  ) -> TripIdea {
    var e = TripIdea.freeform(
      id: UUID(), tripID: UUID(), title: title, note: note,
      latitude: latitude, longitude: longitude, shortlistRank: rank)
    e.dayRank = dayRank ?? Double(rank)
    e.apply(schedule)
    return e
  }

  func plan(_ entries: [TripIdea], ideas: [Idea], lengthInDays: Int = 3) -> TripPlan {
    TripPlan(
      entries: entries,
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: lengthInDays
    )
  }

  @Test func shortlistIsRankOrderedAndScheduledExcluded() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let entries = [
      entry(idea: a, status: .shortlisted, rank: 2),
      entry(idea: b, status: .shortlisted, rank: 0),
      entry(idea: c, status: .scheduled, rank: 1, schedule: .day(1)),  // not on shortlist
    ]
    let p = plan(entries, ideas: [idea(a), idea(b), idea(c)])
    #expect(p.shortlist.map { $0.idea!.id } == [b, a])
  }

  @Test func scheduledOrdersByDayThenTimeOfDay() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let entries = [
      entry(idea: a, status: .scheduled, schedule: .daypart(2, .lunch)),
      entry(idea: b, status: .scheduled, schedule: .day(1)),
      entry(idea: c, status: .scheduled, schedule: .timed(1, start: "08:00", end: nil)),
    ]
    let p = plan(entries, ideas: [idea(a), idea(b), idea(c)])
    #expect(p.scheduled.map { $0.idea!.id } == [c, b, a])  // day1 08:00, day1 bare, day2 lunch
  }

  // ADR-0033: untimed ("Anytime") stops on the same day order by `dayRank`, the
  // manual intra-day position — no longer piled at the day's end by pool rank.
  @Test func anytimeStopsOrderByDayRankNotShortlistRank() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    // Shortlist rank and day rank are deliberately *opposed*: if the old
    // shortlistRank tiebreak were still in effect this would come back [a, b, c].
    let entries = [
      entry(idea: a, status: .scheduled, rank: 0, dayRank: 2, schedule: .day(1)),
      entry(idea: b, status: .scheduled, rank: 1, dayRank: 1, schedule: .day(1)),
      entry(idea: c, status: .scheduled, rank: 2, dayRank: 0, schedule: .day(1)),
    ]
    let p = plan(entries, ideas: [idea(a), idea(b), idea(c)])
    #expect(p.itinerary[0].stops.map { $0.idea!.id } == [c, b, a])
    #expect(p.scheduled.map { $0.idea!.id } == [c, b, a])
  }

  // An Anytime stop can be positioned *between* timed stops via `dayRank` while the
  // timed stops themselves stay ordered by clock time (time still wins over rank).
  @Test func timedStopsStayTimeOrderedRegardlessOfDayRank() {
    let (morning, anytime, evening) = (UUID(), UUID(), UUID())
    let entries = [
      // A high dayRank must not drag a timed stop out of its clock position.
      entry(idea: evening, status: .scheduled, dayRank: 0, schedule: .timed(1, start: "20:00", end: nil)),
      entry(idea: anytime, status: .scheduled, dayRank: 5, schedule: .day(1)),
      entry(idea: morning, status: .scheduled, dayRank: 9, schedule: .timed(1, start: "09:00", end: nil)),
    ]
    let p = plan(entries, ideas: [idea(morning), idea(anytime), idea(evening)])
    // 09:00 and 20:00 keep their clock order; the Anytime stop (dayRank 5) sits
    // after evening (dayRank 0) in manual order, so it anchors to evening and
    // trails it (Slice 2). Order is unchanged from the Slice 1 end-of-day pile here.
    #expect(p.itinerary[0].stops.map { $0.idea!.id } == [morning, evening, anytime])
  }

  // `dayRank` breaks ties among stops sharing the same clock time.
  @Test func dayRankBreaksTiesAmongEquallyTimedStops() {
    let (first, second) = (UUID(), UUID())
    let entries = [
      entry(idea: second, status: .scheduled, dayRank: 1, schedule: .timed(1, start: "12:00", end: nil)),
      entry(idea: first, status: .scheduled, dayRank: 0, schedule: .timed(1, start: "12:00", end: nil)),
    ]
    let p = plan(entries, ideas: [idea(first), idea(second)])
    #expect(p.itinerary[0].stops.map { $0.idea!.id } == [first, second])
  }

  // ADR-0033 Slice 2: an Anytime stop dropped *after* the 10:00 stop (dayRank
  // between the two timed stops) anchors to 10:00 and sorts before the 14:00 stop —
  // the headline "coffee, sometime after the museum, before the 2pm tour" case.
  @Test func anytimeStopAnchorsBetweenTimedStopsByDayRank() {
    let (museum, coffee, tour) = (UUID(), UUID(), UUID())
    let entries = [
      entry(idea: museum, status: .scheduled, dayRank: 0, schedule: .timed(1, start: "10:00", end: "12:00")),
      entry(idea: coffee, status: .scheduled, dayRank: 1, schedule: .day(1)),           // dropped after museum
      entry(idea: tour, status: .scheduled, dayRank: 2, schedule: .timed(1, start: "14:00", end: nil)),
    ]
    let p = plan(entries, ideas: [idea(museum), idea(coffee), idea(tour)])
    #expect(p.itinerary[0].stops.map { $0.idea!.id } == [museum, coffee, tour])
    #expect(p.scheduled.map { $0.idea!.id } == [museum, coffee, tour])
  }

  // Two Anytime stops sharing a gap keep their manual `dayRank` order behind their
  // common anchor, and ahead of the next timed stop.
  @Test func multipleAnytimeStopsShareAnAnchorInDayRankOrder() {
    let (lunch, walk, nap, dinner) = (UUID(), UUID(), UUID(), UUID())
    let entries = [
      entry(idea: lunch, status: .scheduled, dayRank: 0, schedule: .timed(1, start: "12:00", end: "13:00")),
      entry(idea: nap, status: .scheduled, dayRank: 2, schedule: .day(1)),
      entry(idea: walk, status: .scheduled, dayRank: 1, schedule: .day(1)),
      entry(idea: dinner, status: .scheduled, dayRank: 3, schedule: .timed(1, start: "19:00", end: nil)),
    ]
    let p = plan(entries, ideas: [idea(lunch), idea(walk), idea(nap), idea(dinner)])
    // Both untimed stops anchor to lunch (12:00) and order walk (rank 1) then nap
    // (rank 2) between lunch and dinner.
    #expect(p.itinerary[0].stops.map { $0.idea!.id } == [lunch, walk, nap, dinner])
  }

  // An Anytime stop with no timed/dayparted stop before it in dayRank order keeps
  // end-of-day placement — nothing regresses for stops the user never positioned.
  @Test func anytimeStopWithNoPrecedingTimedStopStaysAtEndOfDay() {
    let (early, wander, late) = (UUID(), UUID(), UUID())
    let entries = [
      // `wander` has the *lowest* dayRank, so no timed stop precedes it: end-of-day.
      entry(idea: wander, status: .scheduled, dayRank: 0, schedule: .day(1)),
      entry(idea: early, status: .scheduled, dayRank: 1, schedule: .timed(1, start: "09:00", end: nil)),
      entry(idea: late, status: .scheduled, dayRank: 2, schedule: .timed(1, start: "17:00", end: nil)),
    ]
    let p = plan(entries, ideas: [idea(early), idea(wander), idea(late)])
    #expect(p.itinerary[0].stops.map { $0.idea!.id } == [early, late, wander])
  }

  @Test func explicitlyLeadingAnytimeStopPrecedesTheFirstTimedStop() {
    let (wander, early) = (UUID(), UUID())
    let entries = [
      entry(idea: wander, status: .scheduled, dayRank: -1, schedule: .day(1)),
      entry(idea: early, status: .scheduled, dayRank: 0, schedule: .timed(1, start: "09:00", end: nil)),
    ]
    let p = plan(entries, ideas: [idea(wander), idea(early)])
    #expect(p.itinerary[0].stops.map { $0.idea!.id } == [wander, early])
  }

  @Test func orphanEntriesAreDroppedFromEveryProjection() {
    // An entry whose idea isn't in the pool lookup (deleted, ADR-0007) resolves
    // to nothing and must not appear anywhere.
    let (kept, orphan) = (UUID(), UUID())
    let entries = [
      entry(idea: kept, status: .shortlisted),
      entry(idea: orphan, status: .shortlisted, rank: 1),
      entry(idea: orphan, status: .scheduled, schedule: .day(1)),
    ]
    let p = plan(entries, ideas: [idea(kept)])  // orphan absent
    #expect(p.shortlist.map { $0.idea!.id } == [kept])
    #expect(p.itinerary.flatMap(\.stops).isEmpty)
  }

  @Test func emptyIsTrueOnlyWithNothingPulled() {
    let bare = plan([], ideas: [])
    #expect(bare.isEmpty)
    #expect(!bare.hasScheduledStops)

    let id = UUID()
    let one = plan([entry(idea: id, status: .considering)], ideas: [idea(id)])
    #expect(!one.isEmpty)
    #expect(one.considering.map { $0.idea!.id } == [id])
  }

  @Test func toBeScheduledIsScheduledWithoutADay() {
    let (placed, unplaced) = (UUID(), UUID())
    let entries = [
      entry(idea: placed, status: .scheduled, schedule: .day(1)),
      entry(idea: unplaced, status: .scheduled, schedule: .unscheduled),  // committed, no day
    ]
    let p = plan(entries, ideas: [idea(placed), idea(unplaced)])
    #expect(p.toBeScheduled.map { $0.idea!.id } == [unplaced])
    #expect(p.hasScheduledStops)
  }

  @Test func canvasGeometryDropsUnlocatedStops() {
    let (located, unlocated) = (UUID(), UUID())
    let entries = [
      entry(idea: located, status: .scheduled, schedule: .day(1)),
      entry(idea: unlocated, status: .scheduled, rank: 1, schedule: .day(1)),
    ]
    let p = plan(entries, ideas: [idea(located), idea(unlocated, lat: nil, lon: nil)])
    #expect(p.hasLocatedStops)
    #expect(p.locatedStops(forDay: 1).map { $0.idea!.id } == [located])
    #expect(p.framingCoordinates(forDay: 1).count == 1)
    #expect(p.framingCoordinates(forDay: nil).count == 1)  // whole trip
  }

  @Test func locatedSequenceNumbersRankLocatedStopsOnly() {
    // Day 1: located A, unlocated B, located C → A=1, C=2, B absent (no pin).
    let (a, b, c) = (UUID(), UUID(), UUID())
    let entries = [
      entry(idea: a, status: .scheduled, rank: 0, schedule: .day(1)),
      entry(idea: b, status: .scheduled, rank: 1, schedule: .day(1)),  // unlocated
      entry(idea: c, status: .scheduled, rank: 2, schedule: .day(1)),
    ]
    let p = plan(entries, ideas: [idea(a), idea(b, lat: nil, lon: nil), idea(c)])
    let stops = p.itinerary[0].stops  // itinerary order [A, B, C]
    let seq = p.locatedSequenceNumbers(forDay: 1)
    #expect(seq[stops[0].id] == 1)    // A
    #expect(seq[stops[2].id] == 2)    // C
    #expect(seq[stops[1].id] == nil)  // B unlocated → no number
  }

  @Test func itineraryHasEveryDayEvenWhenEmpty() {
    let id = UUID()
    let p = plan([entry(idea: id, status: .scheduled, schedule: .day(2))], ideas: [idea(id)], lengthInDays: 3)
    #expect(p.itinerary.map(\.number) == [1, 2, 3])
    #expect(p.itinerary[0].stops.isEmpty)
    #expect(p.itinerary[1].stops.map { $0.idea!.id } == [id])
  }

  // MARK: - Travel connector tests

  @Test func allLegsCoversEveryConsecutiveLocatedPair() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let entries = [
      entry(idea: a, status: .scheduled, schedule: .day(1)),
      entry(idea: b, status: .scheduled, schedule: .day(1)),
      entry(idea: c, status: .scheduled, schedule: .day(2)),
    ]
    // a→b on day 1, nothing on day 2 (c is alone)
    let p = plan(entries, ideas: [
      idea(a, lat: 1, lon: 1), idea(b, lat: 2, lon: 2), idea(c, lat: 3, lon: 3),
    ])
    #expect(p.allLegs.count == 1)
    #expect(p.allLegs.first == LegKey(fromLat: 1, fromLon: 1, toLat: 2, toLon: 2))
  }

  @Test func unlocatedStopBreaksConnectorChain() {
    let (a, c) = (UUID(), UUID())
    let entries = [
      entry(idea: a, status: .scheduled, schedule: .day(1)),
      freeformEntry(title: "Unplaced note", schedule: .day(1)),  // unlocated
      entry(idea: c, status: .scheduled, schedule: .day(1)),
    ]
    let p = plan(entries, ideas: [
      idea(a, lat: 1, lon: 1), idea(c, lat: 3, lon: 3),
    ])
    // The location-less freeform stop breaks both sides of the connector chain.
    #expect(p.legs(forDay: 1).isEmpty)
  }

  @Test func locatedFreeformStopIsLocatedAndProducesLegs() {
    let ideaID = UUID()
    let freeform = freeformEntry(
      title: "Train station",
      latitude: 2,
      longitude: 2,
      schedule: .day(1))
    let ideaStop = entry(idea: ideaID, status: .scheduled, schedule: .day(1))
    let p = plan([freeform, ideaStop], ideas: [idea(ideaID, lat: 3, lon: 3)])

    #expect(p.locatedStops(forDay: 1).map(\.id) == [freeform.id, ideaStop.id])
    #expect(p.itinerary[0].stops[0].content.latitude == 2)
    #expect(p.itinerary[0].stops[0].content.longitude == 2)
    #expect(p.legs(forDay: 1) == [LegKey(fromLat: 2, fromLon: 2, toLat: 3, toLon: 3)])
  }

  @Test func itineraryItemsInterleaveConnectors() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let entries = [
      entry(idea: a, status: .scheduled, schedule: .day(1)),
      entry(idea: b, status: .scheduled, schedule: .day(1)),
      entry(idea: c, status: .scheduled, schedule: .day(1)),
    ]
    let p = plan(entries, ideas: [
      idea(a, lat: 1, lon: 1), idea(b, lat: 2, lon: 2), idea(c, lat: 3, lon: 3),
    ])
    let tt = TravelTime(seconds: 480, meters: 600)
    let leg1 = LegKey(fromLat: 1, fromLon: 1, toLat: 2, toLon: 2)
    let leg2 = LegKey(fromLat: 2, fromLon: 2, toLat: 3, toLon: 3)
    let modes: [LegKey: TransportMode] = [leg1: .walking, leg2: .walking]
    let items = p.itineraryItems(
      forDay: 1,
      travelTimes: [leg1: [.walking: tt]],
      effectiveModes: modes)
    // stop A, connector(loaded), stop B, connector(loading), stop C
    #expect(items.count == 5)
    if case .connector(let c1) = items[1] { #expect(c1.travelTime == tt) }
    else { Issue.record("expected connector at [1]") }
    if case .connector(let c2) = items[3] { #expect(c2.travelTime == nil) }  // leg2 not loaded
    else { Issue.record("expected connector at [3]") }
  }

  // MARK: - Now marker tests

  /// Fixed date: 2026-06-20 15:30 local time — afternoon of day 2 in a trip
  /// that started 2026-06-19. Used across the now-marker tests.
  var june20_1530: Date {
    var c = DateComponents()
    c.year = 2026; c.month = 6; c.day = 20; c.hour = 15; c.minute = 30
    return Calendar.current.date(from: c)!
  }
  var tripStartJune19: Date {
    var c = DateComponents()
    c.year = 2026; c.month = 6; c.day = 19; c.hour = 0; c.minute = 0
    return Calendar.current.date(from: c)!
  }

  @Test func nowMarkerAbsentForUndatedTrip() {
    let id = UUID()
    let p = plan([entry(idea: id, status: .scheduled, schedule: .timed(2, start: "09:00", end: nil))],
                 ideas: [idea(id)])
    let items = p.itineraryItems(forDay: 2, travelTimes: [:], effectiveModes: [:],
                                 now: june20_1530, tripStartDate: nil)
    #expect(!items.contains(.nowMarker))
  }

  @Test func nowMarkerAbsentOnNonCurrentDay() {
    let id = UUID()
    let p = plan([entry(idea: id, status: .scheduled, schedule: .timed(1, start: "09:00", end: nil))],
                 ideas: [idea(id)])
    // now = day 2, looking at day 1 — marker should not appear on day 1
    let items = p.itineraryItems(forDay: 1, travelTimes: [:], effectiveModes: [:],
                                 now: june20_1530, tripStartDate: tripStartJune19)
    #expect(!items.contains(.nowMarker))
  }

  @Test func nowMarkerBeforeFirstFutureStop() {
    let (a, b) = (UUID(), UUID())
    // Day 2: 09:00 stop (past), 18:00 stop (future) — now = 15:30
    let entries = [
      entry(idea: a, status: .scheduled, schedule: .timed(2, start: "09:00", end: nil)),
      entry(idea: b, status: .scheduled, schedule: .timed(2, start: "18:00", end: nil)),
    ]
    let p = plan(entries, ideas: [idea(a, lat: nil, lon: nil), idea(b, lat: nil, lon: nil)])
    let items = p.itineraryItems(forDay: 2, travelTimes: [:], effectiveModes: [:],
                                 now: june20_1530, tripStartDate: tripStartJune19)
    // Expected: stop(a), nowMarker, stop(b)
    #expect(items.count == 3)
    #expect(items[0] == .stop(p.itinerary[1].stops[0]))
    #expect(items[1] == .nowMarker)
  }

  @Test func nowMarkerAfterAllStopsWhenAllPast() {
    let id = UUID()
    // Day 2: 09:00 stop — now = 15:30, so the stop is past
    let p = plan([entry(idea: id, status: .scheduled, schedule: .timed(2, start: "09:00", end: nil))],
                 ideas: [idea(id, lat: nil, lon: nil)])
    let items = p.itineraryItems(forDay: 2, travelTimes: [:], effectiveModes: [:],
                                 now: june20_1530, tripStartDate: tripStartJune19)
    // stop(a), nowMarker — marker trails the last past stop
    #expect(items.last == .nowMarker)
  }

  @Test func nowMarkerBeforeFirstStopWhenAllFuture() {
    let id = UUID()
    // Day 2: 20:00 dinner — now = 15:30, so the stop is future
    let p = plan([entry(idea: id, status: .scheduled, schedule: .timed(2, start: "20:00", end: nil))],
                 ideas: [idea(id, lat: nil, lon: nil)])
    let items = p.itineraryItems(forDay: 2, travelTimes: [:], effectiveModes: [:],
                                 now: june20_1530, tripStartDate: tripStartJune19)
    // nowMarker, stop — marker leads
    #expect(items.first == .nowMarker)
  }

  @Test func connectorAbsentForUnlocatedNeighbour() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let entries = [
      entry(idea: a, status: .scheduled, schedule: .day(1)),
      entry(idea: b, status: .scheduled, schedule: .day(1)),  // unlocated
      entry(idea: c, status: .scheduled, schedule: .day(1)),
    ]
    let p = plan(entries, ideas: [
      idea(a, lat: 1, lon: 1), idea(b, lat: nil, lon: nil), idea(c, lat: 3, lon: 3),
    ])
    let items = p.itineraryItems(forDay: 1, travelTimes: [:], effectiveModes: [:])
    // 3 stops, no connectors (b lacks coords on both sides)
    #expect(items.count == 3)
    #expect(items.allSatisfy { if case .stop = $0 { true } else { false } })
  }

  // MARK: - Freeform stop tests (ADR-0010)

  @Test func freeformStopResolvesAsContent() {
    let e = freeformEntry(title: "Lunch break", note: "Try the local place")
    let p = plan([e], ideas: [])
    // Freeform stops are born .scheduled so they appear in the itinerary when placed
    let e2 = freeformEntry(title: "Check in", schedule: .day(1))
    let p2 = plan([e2], ideas: [], lengthInDays: 2)
    #expect(p2.itinerary[0].stops.count == 1)
    let stop = p2.itinerary[0].stops[0]
    if case let .freeform(title, note, _) = stop.content {
      #expect(title == "Check in")
      #expect(note == nil)
    } else {
      Issue.record("expected .freeform content")
    }
    #expect(stop.idea == nil)
    _ = p  // suppress unused-variable warning; unplaced entry lands in toBeScheduled
    #expect(p.toBeScheduled.count == 1)
    if case let .freeform(title, note, _) = p.toBeScheduled[0].content {
      #expect(title == "Lunch break")
      #expect(note == "Try the local place")
    } else {
      Issue.record("expected .freeform content in toBeScheduled")
    }
  }

  @Test func freeformStopHasNoCoordinateAndProducesNoLeg() {
    let (a, b) = (UUID(), UUID())
    let entries2 = [
      entry(idea: a, status: .scheduled, schedule: .day(1)),
      freeformEntry(title: "Lunch break", schedule: .day(1)),
      entry(idea: b, status: .scheduled, schedule: .day(1)),
    ]
    let p = plan(entries2, ideas: [idea(a, lat: 1, lon: 1), idea(b, lat: 2, lon: 2)])
    // 3 stops on day 1; freeform in the middle has no coords → breaks the leg chain
    #expect(p.legs(forDay: 1).isEmpty)
    #expect(!p.hasLocatedStops == false)  // located idea stops ARE present
    #expect(p.hasLocatedStops)
    // But freeform does not appear in locatedStops
    #expect(p.locatedStops(forDay: 1).count == 2)
    #expect(p.locatedStops(forDay: 1).allSatisfy { $0.content.latitude != nil })
  }

  @Test func partialFreeformCoordinateResolvesAsUnlocated() {
    let stop = freeformEntry(title: "Incomplete location", latitude: 1, longitude: nil)
    let resolved = plan([stop], ideas: [], lengthInDays: 2).toBeScheduled[0]

    #expect(resolved.content.coordinate == nil)
    #expect(resolved.content.latitude == nil)
    #expect(resolved.content.longitude == nil)
  }

  @Test func freeformStopAppearsInItineraryItems() {
    let (a, b) = (UUID(), UUID())
    let entries = [
      entry(idea: a, status: .scheduled, schedule: .timed(1, start: "09:00", end: nil)),
      // 12:00 clock time places "Lunch" between the two timed idea stops in sort order
      freeformEntry(title: "Lunch", schedule: .timed(1, start: "12:00", end: nil)),
      entry(idea: b, status: .scheduled, schedule: .timed(1, start: "14:00", end: nil)),
    ]
    let p = plan(entries, ideas: [idea(a, lat: nil, lon: nil), idea(b, lat: nil, lon: nil)])
    let items = p.itineraryItems(forDay: 1, travelTimes: [:], effectiveModes: [:])
    // All 3 stops; no connectors (none are located)
    #expect(items.count == 3)
    #expect(items.allSatisfy { if case .stop = $0 { true } else { false } })
    if case let .stop(resolved) = items[1] {
      if case let .freeform(title, _, _) = resolved.content {
        #expect(title == "Lunch")
      } else {
        Issue.record("middle item should be freeform stop")
      }
    } else {
      Issue.record("expected stop at [1]")
    }
  }

  @Test func malformedFreeformEntryIsDropped() {
    // An entry with no ideaID and no inlineTitle is invalid — dropped from every
    // projection rather than crashing, and the corrupt row is reported once when
    // the read-model is built (a single chokepoint, ADR-0035 review follow-up).
    let bad = TripIdea(id: UUID(), tripID: UUID(), ideaID: nil, inlineTitle: nil, status: .scheduled)
    let bad2 = TripIdea(id: UUID(), tripID: UUID(), ideaID: nil, inlineTitle: "", status: .scheduled)
    let good = freeformEntry(title: "Check in", schedule: .day(1))
    var p: TripPlan!
    withKnownIssue("two corrupt rows are reported at build", isIntermittent: false) {
      p = plan([bad, bad2, good], ideas: [], lengthInDays: 2)
    }
    // Only the valid freeform stop survives
    #expect(p.itinerary[0].stops.count == 1)
    if case let .freeform(title, _, _) = p.itinerary[0].stops[0].content {
      #expect(title == "Check in")
    } else {
      Issue.record("expected freeform content")
    }
  }

  @Test func freeformStopContentTitle() {
    let id = UUID()
    let ideaStop = ResolvedStop(
      entry: TripIdea(id: UUID(), tripID: UUID(), ideaID: id, status: .scheduled),
      content: .idea(Idea(id: id, name: "Tivoli"))
    )
    let freeformStop = ResolvedStop(
      entry: TripIdea.freeform(id: UUID(), tripID: UUID(), title: "Train to Aarhus"),
      content: .freeform(title: "Train to Aarhus", note: nil, coordinate: nil)
    )
    #expect(ideaStop.content.title == "Tivoli")
    #expect(freeformStop.content.title == "Train to Aarhus")
    #expect(ideaStop.content.latitude != nil || ideaStop.content.latitude == nil)  // just tests access
    #expect(freeformStop.content.latitude == nil)
    #expect(freeformStop.content.longitude == nil)
  }
}
