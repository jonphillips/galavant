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
    // check-out, stop, check-in
    #expect(items.count == 3)
    if case .checkOut(let r) = items[0] { #expect(r.id == leaving.id) } else { Issue.record("want check-out first") }
    if case .stop = items[1] {} else { Issue.record("want stop in the middle") }
    if case .checkIn(let r) = items[2] { #expect(r.id == arriving.id) } else { Issue.record("want check-in last") }
  }

  @Test func middleDayOfAStayHasNoBoundaryRow() {
    // Day 3 sits inside stay (checkIn 2, checkOut 4) — covered, but no boundary.
    let (h, s) = (UUID(), UUID())
    let spanning = stay(idea: h, checkIn: 2, checkOut: 4)
    var stop = TripIdea(id: UUID(), tripID: UUID(), ideaID: s, status: .scheduled)
    stop.apply(.timed(3, start: "10:00", end: nil))
    let p = planWith(stops: [stop], stays: [spanning], ideas: [idea(h), idea(s)])
    let items = p.itineraryItems(
      forDay: 3, travelTimes: [:], effectiveModes: [:], stays: p.stays(coveringDay: 3))
    #expect(items.count == 1)
    if case .stop = items[0] {} else { Issue.record("middle day should show only the stop") }
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
}
