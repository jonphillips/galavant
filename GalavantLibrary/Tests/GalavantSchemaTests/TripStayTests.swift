import Foundation
import GalavantSchema
import Testing

/// `TripStay` is the sibling accommodation record (ADR-0011); these tests exercise
/// its pure helpers and the `TripPlan` stay projections as plain values — no
/// database — mirroring `TripPlanTests`.
@Suite struct TripStayTests {
  func idea(_ id: Idea.ID, name: String = "Hotel", lat: Double? = 1, lon: Double? = 1) -> Idea {
    Idea(id: id, name: name, latitude: lat, longitude: lon)
  }

  func stay(
    idea: Idea.ID? = nil,
    title: String? = nil,
    checkIn: Int,
    checkOut: Int,
    checkInTime: String? = nil,
    checkOutTime: String? = nil
  ) -> TripStay {
    TripStay(
      id: UUID(), tripID: UUID(), ideaID: idea,
      inlineTitle: title, checkInDay: checkIn, checkOutDay: checkOut,
      checkInTime: checkInTime, checkOutTime: checkOutTime
    )
  }

  func plan(stays: [TripStay], ideas: [Idea], lengthInDays: Int = 5) -> TripPlan {
    TripPlan(
      entries: [],
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: lengthInDays,
      tripStays: stays
    )
  }

  // MARK: - Span helpers

  @Test func coversIsInclusiveOfBothBoundaries() {
    let s = stay(checkIn: 2, checkOut: 4)
    #expect(!s.covers(day: 1))
    #expect(s.covers(day: 2))  // check-in day
    #expect(s.covers(day: 3))
    #expect(s.covers(day: 4))  // check-out day
    #expect(!s.covers(day: 5))
  }

  @Test func nightsAreCheckInUpToButNotCheckOut() {
    // Check in day 2, out day 5 → sleep nights 2, 3, 4 (not 5, you leave that morning)
    #expect(Array(stay(checkIn: 2, checkOut: 5).nights) == [2, 3, 4])
  }

  // MARK: - Sort minutes

  @Test func sortMinutesUseTimeOrFallBackToDefaults() {
    let untimed = stay(checkIn: 1, checkOut: 2)
    #expect(untimed.checkInSortMinutes == 18 * 60)   // evening default
    #expect(untimed.checkOutSortMinutes == 10 * 60)  // morning default

    let timed = stay(checkIn: 1, checkOut: 2, checkInTime: "15:00", checkOutTime: "08:30")
    #expect(timed.checkInSortMinutes == 15 * 60)
    #expect(timed.checkOutSortMinutes == 8 * 60 + 30)
  }

  // MARK: - Overlap (pure)

  @Test func overlapFlagsStaysSharingANight() {
    // A: nights 1,2  B: nights 2,3 → share night 2.  C: nights 4 → clear.
    let a = stay(checkIn: 1, checkOut: 3)
    let b = stay(checkIn: 2, checkOut: 4)
    let c = stay(checkIn: 4, checkOut: 5)
    let flagged = TripStay.overlapping([a, b, c])
    #expect(flagged == [a.id, b.id])
  }

  @Test func adjacentStaysDoNotOverlap() {
    // Change hotels: check out of A on day 3, check into B on day 3 — A sleeps
    // nights 1,2; B sleeps nights 3,4. No shared night, no flag.
    let a = stay(checkIn: 1, checkOut: 3)
    let b = stay(checkIn: 3, checkOut: 5)
    #expect(TripStay.overlapping([a, b]).isEmpty)
  }

  // MARK: - TripPlan projections

  @Test func staysAreSpanOrderedAndResolved() {
    let (h1, h2) = (UUID(), UUID())
    let later = stay(idea: h2, checkIn: 4, checkOut: 6)
    let earlier = stay(idea: h1, checkIn: 1, checkOut: 4)
    let p = plan(stays: [later, earlier], ideas: [idea(h1, name: "First"), idea(h2, name: "Second")])
    #expect(p.stays.map { $0.content.title } == ["First", "Second"])
    #expect(p.hasStays)
  }

  @Test func staysCoveringDayIsInclusive() {
    let (h1, h2) = (UUID(), UUID())
    let a = stay(idea: h1, checkIn: 1, checkOut: 3)
    let b = stay(idea: h2, checkIn: 3, checkOut: 5)
    let p = plan(stays: [a, b], ideas: [idea(h1), idea(h2)])
    #expect(p.stays(coveringDay: 2).map(\.id) == [a.id])
    #expect(Set(p.stays(coveringDay: 3).map(\.id)) == [a.id, b.id])  // both touch day 3
    #expect(p.stays(coveringDay: 4).map(\.id) == [b.id])
  }

  @Test func freeformStayResolvesWithoutCoordinate() {
    let s = stay(title: "Airbnb — conf #1234", checkIn: 1, checkOut: 3)
    let p = plan(stays: [s], ideas: [])
    let resolved = p.stays
    #expect(resolved.count == 1)
    #expect(resolved[0].content.title == "Airbnb — conf #1234")
    #expect(resolved[0].idea == nil)
    #expect(resolved[0].content.latitude == nil)  // freeform → falls out of canvas
  }

  @Test func orphanStaysDrop() {
    let present = UUID()
    let orphan = UUID()  // referenced but absent from the pool
    let staysIn = [
      stay(idea: present, checkIn: 1, checkOut: 2),
      stay(idea: orphan, checkIn: 1, checkOut: 2),
    ]
    let p = plan(stays: staysIn, ideas: [idea(present)])
    #expect(p.stays.map(\.idea?.id) == [present])
  }

  @Test func malformedStayDropsAndReportsIssue() {
    // Neither ideaID nor inlineTitle — a should-never-happen write. It drops on
    // read and reports an issue (asserted via withKnownIssue), never crashing.
    let bad = TripStay(
      id: UUID(), tripID: UUID(), ideaID: nil, inlineTitle: nil, checkInDay: 1, checkOutDay: 2)
    let p = plan(stays: [bad], ideas: [])
    withKnownIssue {
      #expect(p.stays.isEmpty)
    }
  }

  // MARK: - Itinerary weaving (check-in / check-out rows)

  func scheduledStop(_ idea: Idea.ID, at start: String) -> TripIdea {
    var e = TripIdea(id: UUID(), tripID: UUID(), ideaID: idea, status: .scheduled)
    e.apply(.timed(2, start: start, end: nil))
    return e
  }

  func planWith(stops: [TripIdea], stays: [TripStay], ideas: [Idea]) -> TripPlan {
    TripPlan(
      entries: stops,
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: 5,
      tripStays: stays
    )
  }

  @Test func untimedBoundariesBracketTheDaysStops() {
    // Day 2 is a stay's check-out day (leaving the old hotel) and another stay's
    // check-in day (arriving at the new one). Untimed → check-out (morning) leads,
    // check-in (evening) trails the day's stops.
    let (h1, h2, s) = (UUID(), UUID(), UUID())
    let leaving = stay(idea: h1, checkIn: 1, checkOut: 2)
    let arriving = stay(idea: h2, checkIn: 2, checkOut: 4)
    let p = planWith(
      stops: [scheduledStop(s, at: "12:00")],
      stays: [leaving, arriving],
      ideas: [idea(h1), idea(h2), idea(s)])
    let items = p.itineraryItems(
      forDay: 2, travelTimes: [:], effectiveModes: [:], stays: p.stays(coveringDay: 2))
    // A transition day has two lodging anchors. Do not guess which hotel's ETA
    // belongs to the noon stop — that was the source of wrong travel rows.
    #expect(items.count == 3)
    if case .checkOut(let r) = items[0] { #expect(r.id == leaving.id) } else { Issue.record("want check-out first") }
    if case .stop = items[1] {} else { Issue.record("want stop between lodging boundaries") }
    if case .checkIn(let r) = items[2] { #expect(r.id == arriving.id) } else { Issue.record("want check-in last") }
  }

  @Test func emptyLodgingTransitionShowsOnlyTheDirectTravelRow() {
    let (h1, h2) = (UUID(), UUID())
    let leaving = stay(idea: h1, checkIn: 1, checkOut: 2)
    let arriving = stay(idea: h2, checkIn: 2, checkOut: 4)
    let p = plan(
      stays: [leaving, arriving],
      ideas: [idea(h1, name: "Uberfahrt", lat: 1, lon: 2), idea(h2, name: "Dichter", lat: 3, lon: 4)])
    let leg = LegKey(fromLat: 1, fromLon: 2, toLat: 3, toLon: 4)
    let travelTime = TravelTime(seconds: 3_600, meters: 55_000)
    let items = p.itineraryItems(
      forDay: 2,
      travelTimes: [leg: [.driving: travelTime]],
      effectiveModes: [leg: .driving],
      stays: p.stays(coveringDay: 2))

    #expect(p.stayTransferLegs(forDay: 2) == [leg])
    #expect(p.allLegs == [leg])
    #expect(items.count == 3)
    if case .checkOut(let stay) = items[0] { #expect(stay.id == leaving.id) }
    else { Issue.record("want check-out first") }
    if case .connector(let connector) = items[1] {
      #expect(connector.kind == .betweenLodgings)
      #expect(connector.from.title == "Uberfahrt")
      #expect(connector.to.title == "Dichter")
      #expect(connector.travelTime == travelTime)
    } else { Issue.record("want direct lodging travel row") }
    if case .checkIn(let stay) = items[2] { #expect(stay.id == arriving.id) }
    else { Issue.record("want check-in last") }
  }

  @Test func middleDayShowsAHomeBaseRowAtopItsStops() {
    // Day 3 sits inside stay (checkIn 2, checkOut 4) — a covered middle day, so it
    // shows a persistent home-base row leading the day, then the stop (ADR-0011,
    // promoted to a real row).
    let (h, s) = (UUID(), UUID())
    let spanning = stay(idea: h, checkIn: 2, checkOut: 4)
    var stop = TripIdea(id: UUID(), tripID: UUID(), ideaID: s, status: .scheduled)
    stop.apply(.timed(3, start: "10:00", end: nil))
    let p = planWith(stops: [stop], stays: [spanning], ideas: [idea(h), idea(s)])
    let items = p.itineraryItems(
      forDay: 3, travelTimes: [:], effectiveModes: [:], stays: p.stays(coveringDay: 3))
    #expect(items.count == 3)
    if case .homeBase(let r) = items[0] { #expect(r.id == spanning.id) }
    else { Issue.record("middle day should lead with the home-base row") }
    if case .connector = items[1] {} else { Issue.record("then the base directions") }
    if case .stop = items[2] {} else { Issue.record("then the day's stop") }
  }

  @Test func boundaryDaysGetTheirEventRowNotAHomeBaseRow() {
    // The check-in day (2) and check-out day (4) carry their event rows; neither
    // doubles up a home-base row (the event names the hotel).
    let h = UUID()
    let spanning = stay(idea: h, checkIn: 2, checkOut: 4)
    let p = planWith(stops: [], stays: [spanning], ideas: [idea(h)])
    let checkInDay = p.itineraryItems(
      forDay: 2, travelTimes: [:], effectiveModes: [:], stays: p.stays(coveringDay: 2))
    let checkOutDay = p.itineraryItems(
      forDay: 4, travelTimes: [:], effectiveModes: [:], stays: p.stays(coveringDay: 4))
    #expect(checkInDay.count == 1)
    if case .checkIn = checkInDay[0] {} else { Issue.record("check-in day shows the check-in row only") }
    #expect(checkOutDay.count == 1)
    if case .checkOut = checkOutDay[0] {} else { Issue.record("check-out day shows the check-out row only") }
  }

  @Test func timedCheckInWeavesAmongStopsByTime() {
    // Check in at 13:00 lands between a 12:00 stop and a 14:00 stop.
    let (h, a, b) = (UUID(), UUID(), UUID())
    let arriving = stay(idea: h, checkIn: 2, checkOut: 4, checkInTime: "13:00")
    let p = planWith(
      stops: [scheduledStop(a, at: "12:00"), scheduledStop(b, at: "14:00")],
      stays: [arriving],
      ideas: [idea(h, lat: nil, lon: nil), idea(a, lat: nil, lon: nil), idea(b, lat: nil, lon: nil)])
    let items = p.itineraryItems(
      forDay: 2, travelTimes: [:], effectiveModes: [:], stays: p.stays(coveringDay: 2))
    // stop(12:00), check-in(13:00), stop(14:00)
    #expect(items.count == 3)
    if case .checkIn = items[1] {} else { Issue.record("check-in should weave into the middle") }
  }

  @Test func boundaryRowsAppearOnAStoplessDay() {
    let h = UUID()
    let arriving = stay(idea: h, checkIn: 2, checkOut: 4)
    let p = planWith(stops: [], stays: [arriving], ideas: [idea(h)])
    let items = p.itineraryItems(
      forDay: 2, travelTimes: [:], effectiveModes: [:], stays: p.stays(coveringDay: 2))
    #expect(items.count == 1)
    if case .checkIn = items[0] {} else { Issue.record("a stop-less check-in day still shows the row") }
  }

  // MARK: - Canvas base pins

  @Test func baseStaysFollowTheLensAndDropUnlocated() {
    let (h1, h2) = (UUID(), UUID())
    let located = stay(idea: h1, checkIn: 1, checkOut: 3)
    let freeform = stay(title: "Couch surfing", checkIn: 1, checkOut: 5)  // no coordinate
    let p = plan(
      stays: [located, freeform],
      ideas: [idea(h1), idea(h2)])  // h2 unused; located hotel only
    // Day lens: only stays covering that day, located only.
    #expect(p.baseStays(forDay: 2).map(\.id) == [located.id])
    #expect(p.baseStays(forDay: 4).isEmpty)  // neither covers day 4 *and* is located
    // "All" lens: every located stay, once each.
    #expect(p.baseStays(forDay: nil).map(\.id) == [located.id])
    #expect(p.baseCoordinates(forDay: 2).count == 1)
  }

  @Test func lodgingPathFollowsChronologicalLocatedStays() {
    let (firstID, secondID, unlocatedID) = (UUID(), UUID(), UUID())
    let first = stay(idea: firstID, checkIn: 1, checkOut: 3)
    let second = stay(idea: secondID, checkIn: 3, checkOut: 5)
    let unlocated = stay(idea: unlocatedID, checkIn: 5, checkOut: 6)
    let p = plan(
      stays: [second, unlocated, first],
      ideas: [
        idea(firstID, name: "First", lat: 10, lon: 20),
        idea(secondID, name: "Second", lat: 30, lon: 40),
        idea(unlocatedID, name: "No pin", lat: nil, lon: nil),
      ],
      lengthInDays: 6)
    #expect(p.lodgingPathCoordinates.map(\.latitude) == [10, 30])
    #expect(p.lodgingPathCoordinates.map(\.longitude) == [20, 40])
  }

  @Test func overlappingStayIDsIgnoresDroppedOrphans() {
    // The orphan would overlap the present stay by night, but it drops on read, so
    // no phantom flag is raised.
    let present = UUID()
    let orphan = UUID()
    let kept = stay(idea: present, checkIn: 1, checkOut: 3)
    let gone = stay(idea: orphan, checkIn: 1, checkOut: 3)
    let p = plan(stays: [kept, gone], ideas: [idea(present)])
    #expect(p.overlappingStayIDs.isEmpty)
  }

  // MARK: - Per-day region (ADR-0012)

  func region(
    _ name: String, lat: Double, lon: Double, latDelta: Double, lonDelta: Double
  ) -> MapRegion {
    MapRegion(
      id: UUID(), name: name,
      centerLatitude: lat, centerLongitude: lon,
      latitudeDelta: latDelta, longitudeDelta: lonDelta)
  }

  func planWith(dayRegions: [TripDayRegion], regions: [MapRegion]) -> TripPlan {
    TripPlan(
      entries: [], ideasByID: [:], lengthInDays: 5,
      dayRegions: dayRegions,
      regionsByID: Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { f, _ in f }))
  }

  @Test func mapRegionBoxIsItsExactCenterAndSpanNoPadding() {
    // The empty-day frame uses the region as drawn, not grown like a stops crop.
    let loire = region("Loire", lat: 47.5, lon: 0.7, latDelta: 1.5, lonDelta: 1.5)
    #expect(loire.box == MapFraming.Box(
      centerLatitude: 47.5, centerLongitude: 0.7, latitudeDelta: 1.5, longitudeDelta: 1.5))
  }

  @Test func regionForDayResolvesTheAssignedRegion() {
    let loire = region("Loire", lat: 47.5, lon: 0.7, latDelta: 1.5, lonDelta: 1.5)
    let assignment = TripDayRegion(id: UUID(), tripID: UUID(), dayNumber: 2, regionID: loire.id)
    let p = planWith(dayRegions: [assignment], regions: [loire])
    #expect(p.region(forDay: 2)?.id == loire.id)
    #expect(p.region(forDay: 3) == nil)  // unassigned day
  }

  @Test func regionForDayDropsAnOrphanAssignment() {
    // The assignment points at a region no longer in the pool (deleted) — it drops
    // out on read, exactly as a TripRegion orphan does.
    let assignment = TripDayRegion(id: UUID(), tripID: UUID(), dayNumber: 2, regionID: UUID())
    let p = planWith(dayRegions: [assignment], regions: [])
    #expect(p.region(forDay: 2) == nil)
  }
}
