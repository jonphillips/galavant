import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import IssueReporting
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TripTests {
  @Dependency(\.defaultDatabase) var database

  // MARK: - Certainty round-trips (pure)

  @Test func certaintyRoundTripsThroughColumns() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let cases: [Certainty] = [
      .someday(rank: 3),
      .targeted(year: 2027, quarter: .q2),
      .targeted(year: 2028, quarter: nil),
      .dated(start: date),
    ]
    for certainty in cases {
      var trip = Trip(id: UUID())
      trip.apply(certainty)
      #expect(trip.certainty == certainty)
    }
  }

  @Test func applyClearsColumnsTheStageDoesntUse() {
    var trip = Trip(id: UUID())
    trip.apply(.targeted(year: 2027, quarter: .q3))
    trip.apply(.someday(rank: 5))
    #expect(trip.targetYear == nil)
    #expect(trip.targetQuarter == nil)
    #expect(trip.startDate == nil)
    #expect(trip.somedayRank == 5)
  }

  @Test func degenerateStoredStateFallsBackToSomeday() {
    withKnownIssue {
      let certainty = Certainty(
        stage: .targeted, somedayRank: 2, targetYear: nil, targetQuarter: nil, startDate: nil
      )
      #expect(certainty == .someday(rank: 2))
    }
  }

  // MARK: - Pure sectioning

  @Test func sectionedOrdersEachStage() {
    let early = Date(timeIntervalSince1970: 1_700_000_000)
    let late = Date(timeIntervalSince1970: 1_800_000_000)
    let trips = [
      trip("Backlog B", .someday(rank: 1)),
      trip("Backlog A", .someday(rank: 0)),
      trip("Later Year", .targeted(year: 2028, quarter: .q1)),
      trip("Same Year Q3", .targeted(year: 2027, quarter: .q3)),
      trip("Same Year Q1", .targeted(year: 2027, quarter: .q1)),
      trip("Departs late", .dated(start: late)),
      trip("Departs early", .dated(start: early)),
    ]
    let sections = Trip.sectioned(trips)
    #expect(sections.someday.map(\.name) == ["Backlog A", "Backlog B"])
    #expect(sections.targeted.map(\.name) == ["Same Year Q1", "Same Year Q3", "Later Year"])
    #expect(sections.dated.map(\.name) == ["Departs early", "Departs late"])
  }

  @Test func activeCapsulesKeepInPlayTripsPlusTopSomeday() {
    let early = Date(timeIntervalSince1970: 1_700_000_000)
    let late = Date(timeIntervalSince1970: 1_800_000_000)
    let trips = [
      trip("Top backlog", .someday(rank: 0)),
      trip("Lower backlog", .someday(rank: 1)),
      trip("Targeted", .targeted(year: 2027, quarter: .q2)),
      trip("Departs late", .dated(start: late)),
      trip("Departs early", .dated(start: early)),
    ]
    // Dated (by date) → targeted → exactly one someday (the top of the backlog).
    #expect(
      Trip.activeCapsules(trips).map(\.name)
        == ["Departs early", "Departs late", "Targeted", "Top backlog"]
    )
  }

  @Test func activeCapsulesWithoutSomedayOmitsThatSlot() {
    let trips = [trip("Targeted", .targeted(year: 2027, quarter: nil))]
    #expect(Trip.activeCapsules(trips).map(\.name) == ["Targeted"])
  }

  // MARK: - Persistence

  @Test func createAppendsSomedayToBottomOfBacklog() async throws {
    let ranks = try await database.write { db -> [Int] in
      let first = try Trip.create(name: "Denmark", in: db)
      let second = try Trip.create(name: "Japan", in: db)
      let third = try Trip.create(name: "Italy", in: db)
      return [first, second, third].map(\.somedayRank)
    }
    #expect(ranks == [0, 1, 2])
  }

  @Test func createTargetedAndDatedSetTheRightColumns() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let (targeted, dated) = try await database.write { db -> (Trip, Trip) in
      let t = try Trip.create(
        name: "Spain", certainty: .targeted(year: 2027, quarter: .q2), lengthInDays: 10, in: db
      )
      let d = try Trip.create(
        name: "Copenhagen", certainty: .dated(start: start), lengthInDays: 9, in: db
      )
      return (t, d)
    }
    #expect(targeted.certainty == .targeted(year: 2027, quarter: .q2))
    #expect(targeted.lengthInDays == 10)
    #expect(dated.certainty == .dated(start: start))
    #expect(dated.lengthInDays == 9)
  }

  @Test func mainTransportModeRoundTripsThroughCreateAndUpdate() async throws {
    let mode = try await database.write { db -> TransportMode? in
      let trip = try Trip.create(name: "Italy", mainTransportMode: .driving, in: db)
      #expect(trip.mainTransportationMode == .driving)
      var draft = Trip.Draft(trip)
      draft.mainTransportMode = TransportMode.transit.rawValue
      try Trip.update(draft, certainty: trip.certainty, in: db)
      return try Trip.find(trip.id).fetchOne(db)?.mainTransportationMode
    }
    #expect(mode == .transit)
  }

  @Test func travelModeOverridePersistsPerTripAndLeg() async throws {
    let modes = try await database.write { db -> [TransportMode?] in
      let trip = try Trip.create(name: "Italy", in: db)
      let leg = LegKey(fromLat: 1, fromLon: 2, toLat: 3, toLon: 4)
      try TripTravelModeOverride.setMode(.transit, for: leg, tripID: trip.id, in: db)
      try TripTravelModeOverride.setMode(.driving, for: leg, tripID: trip.id, in: db)
      return try TripTravelModeOverride
        .where { $0.tripID.eq(trip.id) }
        .fetchAll(db)
        .map(\.mode)
    }
    #expect(modes == [.driving])
  }

  @Test func reorderSomedayPersistsNewRanks() async throws {
    let reordered = try await database.write { db -> [String] in
      let a = try Trip.create(name: "A", in: db)
      let b = try Trip.create(name: "B", in: db)
      let c = try Trip.create(name: "C", in: db)
      try Trip.reorderSomeday([c.id, a.id, b.id], in: db)
      return Trip.sectioned(try Trip.all.fetchAll(db)).someday.map(\.name)
    }
    #expect(reordered == ["C", "A", "B"])
  }

  @Test func updatePreservesSomedayRankWhenStayingInBacklog() async throws {
    let rank = try await database.write { db -> Int in
      let trip = try Trip.create(name: "First", in: db)
      _ = try Trip.create(name: "Second", in: db)
      var draft = Trip.Draft(trip)
      draft.name = "First (renamed)"
      try Trip.update(draft, certainty: .someday(rank: trip.somedayRank), in: db)
      return try Trip.find(trip.id).fetchOne(db)!.somedayRank
    }
    #expect(rank == 0)
  }

  @Test func updateMovingIntoSomedayAppendsToBottom() async throws {
    let rank = try await database.write { db -> Int in
      _ = try Trip.create(name: "Backlog 0", in: db)
      _ = try Trip.create(name: "Backlog 1", in: db)
      let targeted = try Trip.create(
        name: "Spain", certainty: .targeted(year: 2027, quarter: .q2), in: db
      )
      let draft = Trip.Draft(targeted)
      try Trip.update(draft, certainty: .someday(rank: 0), in: db)
      return try Trip.find(targeted.id).fetchOne(db)!.somedayRank
    }
    #expect(rank == 2)
  }

  // MARK: - TripIdea lifecycle (ADR-0004)

  @Test func pullIsIdempotent() async throws {
    let count = try await database.write { db -> Int in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let idea = try seedIdea(name: "Tivoli", in: db)
      try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchCount(db)
    }
    #expect(count == 1)
  }

  @Test func scheduledRepeatCreatesAnIndependentOccurrence() async throws {
    let entries = try await database.write { db -> [TripIdea] in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let idea = try seedIdea(name: "Noma", in: db)
      _ = try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      _ = try TripIdea.repeatScheduled(ideaID: idea.id, into: trip.id, on: .day(1), in: db)
      _ = try TripIdea.repeatScheduled(ideaID: idea.id, into: trip.id, on: .day(2), in: db)
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
    }
    #expect(entries.count == 3)  // one shortlist membership, two itinerary visits
    #expect(entries.filter { $0.status == .scheduled }.compactMap(\.dayNumber).sorted() == [1, 2])
  }

  @Test func statusAdvancesThroughLifecycle() async throws {
    let status = try await database.write { db -> TripIdeaStatus? in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let idea = try seedIdea(name: "Noma", in: db)
      let pulled = try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      #expect(pulled.status == .considering)
      try TripIdea.setStatus(.shortlisted, ideaID: idea.id, tripID: trip.id, in: db)
      return try TripIdea.find(pulled.id).fetchOne(db)?.status
    }
    #expect(status == .shortlisted)
    #expect(status?.isOnShortlist == true)
  }

  @Test func removeTakesIdeaOffTheTrip() async throws {
    let count = try await database.write { db -> Int in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let idea = try seedIdea(name: "Strøget", in: db)
      try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      try TripIdea.remove(ideaID: idea.id, from: trip.id, in: db)
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchCount(db)
    }
    #expect(count == 0)
  }

  @Test func deletingTripCascadesItsTripIdeas() async throws {
    let count = try await database.write { db -> Int in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let idea = try seedIdea(name: "Nyhavn", in: db)
      try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      try Trip.find(trip.id).delete().execute(db)
      return try TripIdea.all.fetchCount(db)
    }
    #expect(count == 0)
  }

  // MARK: - Shortlist ranking (M3b)

  @Test func promotingToShortlistAppendsRanks() async throws {
    let ranks = try await database.write { db -> [Int] in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let a = try seedIdea(name: "Tivoli", in: db)
      let b = try seedIdea(name: "Noma", in: db)
      try TripIdea.pull(ideaID: a.id, into: trip.id, in: db)
      try TripIdea.pull(ideaID: b.id, into: trip.id, in: db)
      try TripIdea.setStatus(.shortlisted, ideaID: a.id, tripID: trip.id, in: db)
      try TripIdea.setStatus(.shortlisted, ideaID: b.id, tripID: trip.id, in: db)
      let entries = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      return TripIdea.shortlist(entries).map(\.shortlistRank)
    }
    #expect(ranks == [0, 1])
  }

  @Test func reorderShortlistPersistsOrder() async throws {
    let order = try await database.write { db -> [String] in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let ideas = try ["A", "B", "C"].map { try seedIdea(name: $0, in: db) }
      for idea in ideas {
        try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
        try TripIdea.setStatus(.shortlisted, ideaID: idea.id, tripID: trip.id, in: db)
      }
      let entries = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      let joinID = Dictionary(uniqueKeysWithValues: entries.map { ($0.ideaID!, $0.id) })
      try TripIdea.reorderShortlist(
        [joinID[ideas[2].id]!, joinID[ideas[0].id]!, joinID[ideas[1].id]!], in: db
      )
      let names = Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0.name) })
      let reordered = TripIdea.shortlist(try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db))
      return reordered.map { names[$0.ideaID!]! }
    }
    #expect(order == ["C", "A", "B"])
  }

  // ADR-0033: reordering a day's stops persists `dayRank` and re-orders the
  // itinerary, independent of the shortlist order.
  @Test func reorderDayStopsPersistsIntraDayOrder() async throws {
    let order = try await database.write { db -> [String] in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let ideas = try ["A", "B", "C"].map { try seedIdea(name: $0, in: db) }
      for idea in ideas {
        try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
        // All three are untimed ("Anytime") on day 1 — the case dayRank governs.
        try TripIdea.schedule(.day(1), ideaID: idea.id, tripID: trip.id, in: db)
      }
      let entries = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      let joinID = Dictionary(uniqueKeysWithValues: entries.map { ($0.ideaID!, $0.id) })
      try TripIdea.reorderDayStops(
        [joinID[ideas[2].id]!, joinID[ideas[0].id]!, joinID[ideas[1].id]!], in: db
      )
      let names = Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0.name) })
      let day1 = TripIdea.itinerary(
        try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db), lengthInDays: 1
      )[0].stops
      return day1.map { names[$0.ideaID!]! }
    }
    #expect(order == ["C", "A", "B"])
  }

  @Test func shortlistAndConsideringPartition() {
    let trip = UUID()
    let entries = [
      TripIdea(id: UUID(), tripID: trip, ideaID: UUID(), status: .considering),
      TripIdea(id: UUID(), tripID: trip, ideaID: UUID(), status: .shortlisted, shortlistRank: 1),
      TripIdea(id: UUID(), tripID: trip, ideaID: UUID(), status: .scheduled, shortlistRank: 0),
      TripIdea(id: UUID(), tripID: trip, ideaID: UUID(), status: .skipped),
    ]
    #expect(TripIdea.considering(entries).count == 1)
    // scheduled (rank 0) and shortlisted (rank 1) are on the shortlist, in rank
    // order; considering and skipped are excluded.
    #expect(TripIdea.shortlist(entries).map(\.shortlistRank) == [0, 1])
  }

  // MARK: - Trip regions (M3b.1)

  @Test func setRegionsReconcilesToExactSet() async throws {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let ids = try await database.write { db -> Set<UUID> in
      let trip = try Trip.create(name: "Denmark", in: db)
      try TripRegion.setRegions([a, b], forTrip: trip.id, in: db)
      try TripRegion.setRegions([b, c], forTrip: trip.id, in: db)  // drop a, add c
      return Set(try TripRegion.regionIDs(forTrip: trip.id, in: db))
    }
    #expect(ids == [b, c])
  }

  @Test func deletingTripCascadesItsRegions() async throws {
    let count = try await database.write { db -> Int in
      let trip = try Trip.create(name: "Denmark", in: db)
      try TripRegion.setRegions([UUID(), UUID()], forTrip: trip.id, in: db)
      try Trip.find(trip.id).delete().execute(db)
      return try TripRegion.all.fetchCount(db)
    }
    #expect(count == 0)
  }

  @Test func setDayRegionReplacesAndClears() async throws {
    let (a, b) = (UUID(), UUID())
    let (afterReassign, afterClear) = try await database.write { db -> (UUID?, UUID?) in
      let trip = try Trip.create(name: "France", in: db)
      try TripDayRegion.setRegion(a, forTrip: trip.id, day: 4, in: db)
      try TripDayRegion.setRegion(b, forTrip: trip.id, day: 4, in: db)  // replaces a
      let reassigned = try TripDayRegion.regionID(forTrip: trip.id, day: 4, in: db)
      try TripDayRegion.setRegion(nil, forTrip: trip.id, day: 4, in: db)  // clears
      let cleared = try TripDayRegion.regionID(forTrip: trip.id, day: 4, in: db)
      return (reassigned, cleared)
    }
    #expect(afterReassign == b)  // at most one row per (trip, day)
    #expect(afterClear == nil)
  }

  @Test func deletingTripCascadesItsDayRegions() async throws {
    let count = try await database.write { db -> Int in
      let trip = try Trip.create(name: "France", in: db)
      try TripDayRegion.setRegion(UUID(), forTrip: trip.id, day: 1, in: db)
      try TripDayRegion.setRegion(UUID(), forTrip: trip.id, day: 2, in: db)
      try Trip.find(trip.id).delete().execute(db)
      return try TripDayRegion.all.fetchCount(db)
    }
    #expect(count == 0)
  }

  // MARK: - Scheduling (M3c)

  @Test func scheduleRoundTripsThroughColumns() {
    let cases: [Schedule] = [
      .unscheduled,
      .day(2),
      .daypart(3, .dinner),
      .timed(4, start: "09:30", end: "11:00"),
      .timed(5, start: "14:00", end: nil),
    ]
    for schedule in cases {
      var entry = TripIdea(id: UUID(), tripID: UUID(), ideaID: UUID())
      entry.apply(schedule)
      #expect(entry.schedule == schedule)
    }
  }

  @Test func applyClearsTheColumnsTheCaseDoesntUse() {
    var entry = TripIdea(id: UUID(), tripID: UUID(), ideaID: UUID())
    entry.apply(.timed(2, start: "08:00", end: "09:00"))
    entry.apply(.daypart(2, .lunch))
    #expect(entry.startTime == nil)
    #expect(entry.endTime == nil)
    entry.apply(.unscheduled)
    #expect(entry.dayNumber == nil)
    #expect(entry.dayPart == nil)
  }

  @Test func intraDaySortOrdersClockThenDaypartThenBareDay() {
    #expect(Schedule.timed(1, start: "09:00", end: nil).intraDaySort == 9 * 60)
    #expect(Schedule.daypart(1, .morning).intraDaySort == DayPart.morning.sortHour * 60)
    // 09:00 (540) < morning (600) < dinner (1080) < a bare day (sorts last).
    let keys = [
      Schedule.timed(1, start: "09:00", end: nil),
      .daypart(1, .morning),
      .daypart(1, .dinner),
      .day(1),
    ].map(\.intraDaySort)
    #expect(keys == keys.sorted())
    #expect(keys.last == Schedule.day(1).intraDaySort)
  }

  @Test func malformedTimeSortsToEndOfDay() {
    withKnownIssue {
      #expect(Schedule.timed(1, start: "nope", end: nil).intraDaySort == Schedule.day(1).intraDaySort)
    }
  }

  // ADR-0033 §3: `suggestedTime` proposes a start from the bracketing timed stops.
  @Test func suggestedTimeProposesASlotFromNeighbors() {
    let cases: [(previous: Schedule?, next: Schedule?, expected: String?)] = [
      // Both sides timed, room after the previous → start when the previous ends.
      (.timed(1, start: "10:00", end: "11:00"), .timed(1, start: "14:00", end: nil), "11:00"),
      // Previous has no end → assume a default block, still lands before the next.
      (.timed(1, start: "10:00", end: nil), .timed(1, start: "14:00", end: nil), "11:00"),
      // No room (previous runs to/past the next) → midpoint of the two starts.
      (.timed(1, start: "13:00", end: "15:00"), .timed(1, start: "14:00", end: nil), "13:30"),
      // Only a previous neighbor → right when it ends.
      (.timed(1, start: "10:00", end: "11:00"), nil, "11:00"),
      (.timed(1, start: "10:00", end: nil), nil, "11:00"),
      // Only a next neighbor → a default block before it, clamped at midnight.
      (nil, .timed(1, start: "09:00", end: nil), "08:00"),
      (nil, .timed(1, start: "00:30", end: nil), "00:00"),
      // Nothing to reason from → nil (the editor stays blank).
      (nil, nil, nil),
      // Non-timed neighbors carry no clock time → treated as absent.
      (.day(1), .daypart(1, .lunch), nil),
    ]
    for c in cases {
      #expect(
        Schedule.suggestedTime(after: c.previous, before: c.next) == c.expected,
        "after \(String(describing: c.previous)) before \(String(describing: c.next))")
    }
  }

  // A neighbor whose time can't be parsed can't anchor; the other neighbor still can.
  @Test func suggestedTimeTreatsMalformedNeighborAsAbsent() {
    withKnownIssue {
      #expect(
        Schedule.suggestedTime(
          after: .timed(1, start: "nope", end: nil),
          before: .timed(1, start: "12:00", end: nil)) == "11:00")
    }
  }

  @Test func itineraryGroupsStopsByDayAndSortsWithinEachDay() {
    let trip = UUID()
    func stop(_ schedule: Schedule, rank: Int, status: TripIdeaStatus = .scheduled) -> TripIdea {
      var entry = TripIdea(id: UUID(), tripID: trip, ideaID: UUID(), status: status, shortlistRank: rank)
      entry.apply(schedule)
      return entry
    }
    let a = stop(.daypart(1, .dinner), rank: 5)
    let b = stop(.timed(1, start: "08:00", end: nil), rank: 9)
    let c = stop(.day(2), rank: 0)
    let e = stop(.daypart(2, .lunch), rank: 0)
    let shortlisted = stop(.unscheduled, rank: 1, status: .shortlisted)
    let outOfRange = stop(.day(9), rank: 0)  // trip only has 3 days → clamps onto day 3

    let days = TripIdea.itinerary([a, b, c, e, shortlisted, outOfRange], lengthInDays: 3)
    #expect(days.map(\.number) == [1, 2, 3])
    #expect(days[0].stops.map(\.id) == [b.id, a.id])  // 08:00 before dinner
    #expect(days[1].stops.map(\.id) == [e.id, c.id])  // lunch before bare day
    #expect(days[2].stops.map(\.id) == [outOfRange.id])
  }

  @Test func itineraryInterleavesTimedAndDaypartsWithinADay() {
    let trip = UUID()
    func stop(_ schedule: Schedule) -> TripIdea {
      var entry = TripIdea(id: UUID(), tripID: trip, ideaID: UUID(), status: .scheduled)
      entry.apply(schedule)
      return entry
    }
    // Two clock times and two dayparts on one day, added out of order. Expected
    // order by minutes-from-midnight: 09:00 (540), morning (600), 14:00 (840),
    // dinner (1080) — i.e. clock times and dayparts sort against each other.
    let dinner = stop(.daypart(1, .dinner))
    let afternoonClock = stop(.timed(1, start: "14:00", end: nil))
    let morning = stop(.daypart(1, .morning))
    let morningClock = stop(.timed(1, start: "09:00", end: "10:30"))
    let days = TripIdea.itinerary([dinner, afternoonClock, morning, morningClock], lengthInDays: 1)
    #expect(days[0].stops.map(\.id) == [morningClock.id, morning.id, afternoonClock.id, dinner.id])
  }

  // ADR-0033: equal-time (here, both bare "Anytime") stops tiebreak by `dayRank`,
  // the manual intra-day order — not by `shortlistRank`, which now only orders the
  // shortlist pile. `shortlistRank` is set opposite to `dayRank` to prove it no
  // longer influences intra-day order.
  @Test func itineraryTiebreaksEqualTimesByDayRank() {
    let trip = UUID()
    func stop(shortlistRank: Int, dayRank: Double) -> TripIdea {
      var entry = TripIdea(
        id: UUID(), tripID: trip, ideaID: UUID(), status: .scheduled,
        shortlistRank: shortlistRank, dayRank: dayRank)
      entry.apply(.day(1))
      return entry
    }
    let high = stop(shortlistRank: 0, dayRank: 2)
    let low = stop(shortlistRank: 1, dayRank: 1)
    let days = TripIdea.itinerary([high, low], lengthInDays: 1)
    #expect(days[0].stops.map(\.id) == [low.id, high.id])
  }

  @Test func scheduleOpSetsStatusAndColumns() async throws {
    let entry = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "Copenhagen", lengthInDays: 5, in: db)
      let idea = try seedIdea(name: "Tivoli", in: db)
      try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      try TripIdea.setStatus(.shortlisted, ideaID: idea.id, tripID: trip.id, in: db)
      try TripIdea.schedule(.daypart(2, .afternoon), ideaID: idea.id, tripID: trip.id, in: db)
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchOne(db)!
    }
    #expect(entry.status == .scheduled)
    #expect(entry.schedule == .daypart(2, .afternoon))
  }

  @Test func unscheduleClearsColumnsAndReturnsToShortlist() async throws {
    let entry = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let idea = try seedIdea(name: "Noma", in: db)
      try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      try TripIdea.schedule(.timed(1, start: "19:00", end: "21:00"), ideaID: idea.id, tripID: trip.id, in: db)
      try TripIdea.unschedule(ideaID: idea.id, tripID: trip.id, in: db)
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchOne(db)!
    }
    #expect(entry.status == .shortlisted)
    #expect(entry.schedule == .unscheduled)
    #expect(entry.dayNumber == nil)
  }

  @Test func scheduleUnplacedFillsTheToBeScheduledBucket() async throws {
    let entries = try await database.write { db -> [TripIdea] in
      let trip = try Trip.create(name: "Copenhagen", lengthInDays: 4, in: db)
      let unplaced = try seedIdea(name: "Reffen", in: db)
      let placed = try seedIdea(name: "Tivoli", in: db)
      for idea in [unplaced, placed] {
        try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      }
      try TripIdea.scheduleUnplaced(ideaID: unplaced.id, tripID: trip.id, in: db)
      try TripIdea.schedule(.day(2), ideaID: placed.id, tripID: trip.id, in: db)
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
    }
    let bucket = TripIdea.toBeScheduled(entries)
    #expect(bucket.count == 1)
    #expect(bucket.first?.status == .scheduled)
    #expect(bucket.first?.schedule == .unscheduled)
    // The unplaced stop stays out of the day grouping until it gets a day.
    let placedOnDays = TripIdea.itinerary(entries, lengthInDays: 4).flatMap(\.stops)
    #expect(placedOnDays.count == 1)
  }

  @Test func markDoneFlipsVisitedButMarkSkippedDoesNot() async throws {
    let (doneVisited, skippedVisited) = try await database.write { db -> (Bool, Bool) in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let doneIdea = try seedIdea(name: "Visited", in: db)
      let skippedIdea = try seedIdea(name: "Untouched", in: db)
      for idea in [doneIdea, skippedIdea] {
        try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
        try TripIdea.schedule(.day(1), ideaID: idea.id, tripID: trip.id, in: db)
      }
      try TripIdea.markDone(ideaID: doneIdea.id, tripID: trip.id, in: db)
      try TripIdea.setStatus(.skipped, ideaID: skippedIdea.id, tripID: trip.id, in: db)
      return (
        try Idea.find(doneIdea.id).fetchOne(db)!.visited,
        try Idea.find(skippedIdea.id).fetchOne(db)!.visited
      )
    }
    #expect(doneVisited == true)
    #expect(skippedVisited == false)
  }

  @Test func dateForDayDerivesFromStartOnlyWhenDated() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let dated = trip("Dated", .dated(start: start))
    #expect(dated.date(forDay: 1) == start)
    #expect(dated.date(forDay: 3) == Calendar.current.date(byAdding: .day, value: 2, to: start))
    #expect(trip("Someday", .someday(rank: 0)).date(forDay: 1) == nil)
  }

  // MARK: - Pinned reservations (docs/trip-time-model.md §4)

  @Test func bookingRoundTripsThroughColumns() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    var entry = TripIdea(id: UUID(), tripID: UUID(), ideaID: UUID())
    #expect(entry.booking == nil)  // no pin, the common case
    entry.pinnedDate = date
    entry.confirmationNumber = "ABC123"
    entry.bookingURL = "https://opentable.com/r/x"
    entry.partySize = 4
    #expect(
      entry.booking
        == ReservationPin(
          date: date, confirmationNumber: "ABC123",
          bookingURL: "https://opentable.com/r/x", partySize: 4))
  }

  // `dayNumber(forPinnedDate:startDate:)` is the exact inverse of `date(forDay:)`:
  // for every day 1...N, pinning to that day's derived date must round-trip back
  // to the same day number.
  @Test func dayNumberForPinnedDateInvertsDateForDay() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    for day in 1...10 {
      let date = Calendar.current.date(byAdding: .day, value: day - 1, to: start)!
      #expect(Trip.dayNumber(forPinnedDate: date, startDate: start) == day)
    }
  }

  @Test func dayNumberForPinnedDateHandlesStartDateSlide() {
    let originalStart = Date(timeIntervalSince1970: 1_700_000_000)  // a Tuesday-ish anchor
    // A reservation pinned to what was day 6 of the original plan.
    let pinnedDate = Calendar.current.date(byAdding: .day, value: 5, to: originalStart)!
    #expect(Trip.dayNumber(forPinnedDate: pinnedDate, startDate: originalStart) == 6)

    // Slide the start date two days later — the pin's real date is unchanged, but
    // it now lands on day 4 (it's two days closer to the new start).
    let laterStart = Calendar.current.date(byAdding: .day, value: 2, to: originalStart)!
    #expect(Trip.dayNumber(forPinnedDate: pinnedDate, startDate: laterStart) == 4)

    // Slide the start date three days earlier — the pin now lands further out, day 9.
    let earlierStart = Calendar.current.date(byAdding: .day, value: -3, to: originalStart)!
    #expect(Trip.dayNumber(forPinnedDate: pinnedDate, startDate: earlierStart) == 9)
  }

  @Test func dayNumberForPinnedDateBeforeStartIsNonPositive() {
    // A pin dated before the (new) start date isn't clamped here — that's the
    // display layer's job (`TripIdea.itinerary` already clamps out-of-range days).
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let earlier = Calendar.current.date(byAdding: .day, value: -2, to: start)!
    #expect(Trip.dayNumber(forPinnedDate: earlier, startDate: start) == -1)
  }

  @Test func setBookingOnADatedTripComputesDayNumberAndSchedules() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = try await database.write { db -> TripIdea in
      let trip = try Trip.create(
        name: "Copenhagen", certainty: .dated(start: start), lengthInDays: 10, in: db)
      let idea = try seedIdea(name: "Noma", in: db)
      let pulled = try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      let pinnedDate = Calendar.current.date(byAdding: .day, value: 5, to: start)!  // day 6
      try TripIdea.setBooking(
        ReservationPin(date: pinnedDate, confirmationNumber: "RES-9", partySize: 2),
        stopID: pulled.id, in: db)
      return try TripIdea.find(pulled.id).fetchOne(db)!
    }
    #expect(entry.status == .scheduled)
    #expect(entry.dayNumber == 6)
    #expect(entry.confirmationNumber == "RES-9")
    #expect(entry.partySize == 2)
  }

  @Test func setBookingOnAnUndatedTripStoresThePinInert() async throws {
    let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "Someday Denmark", in: db)  // undated (someday)
      let idea = try seedIdea(name: "Noma", in: db)
      let pulled = try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      try TripIdea.setBooking(ReservationPin(date: pinnedDate), stopID: pulled.id, in: db)
      return try TripIdea.find(pulled.id).fetchOne(db)!
    }
    // The pin round-trips through storage even with no start date to derive against.
    #expect(entry.pinnedDate == pinnedDate)
    #expect(entry.status == .scheduled)
    #expect(entry.dayNumber == nil)
  }

  @Test func unpinningLeavesDayNumberAndStatusAlone() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "Copenhagen", certainty: .dated(start: start), in: db)
      let idea = try seedIdea(name: "Noma", in: db)
      let pulled = try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      let pinnedDate = Calendar.current.date(byAdding: .day, value: 2, to: start)!  // day 3
      try TripIdea.setBooking(ReservationPin(date: pinnedDate), stopID: pulled.id, in: db)
      try TripIdea.setBooking(nil, stopID: pulled.id, in: db)
      return try TripIdea.find(pulled.id).fetchOne(db)!
    }
    #expect(entry.booking == nil)
    #expect(entry.status == .scheduled)  // untouched, still where the pin left it
    #expect(entry.dayNumber == 3)
  }

  @Test func applyingCalendarCommitmentPinsAndTimesAStop() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let commitmentStart = Calendar.current.date(byAdding: .day, value: 2, to: start)!
    let commitmentEnd = Calendar.current.date(byAdding: .hour, value: 2, to: commitmentStart)!
    let startComponents = Calendar.current.dateComponents([.hour, .minute], from: commitmentStart)
    let endComponents = Calendar.current.dateComponents([.hour, .minute], from: commitmentEnd)
    let expectedStart = String(format: "%02d:%02d", startComponents.hour!, startComponents.minute!)
    let expectedEnd = String(format: "%02d:%02d", endComponents.hour!, endComponents.minute!)
    let entry = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "Copenhagen", certainty: .dated(start: start), in: db)
      let idea = try seedIdea(name: "Noma", in: db)
      let pulled = try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      try TripIdea.applyCalendarCommitment(
        .timed(start: commitmentStart, end: commitmentEnd),
        stopID: pulled.id,
        dayNumber: 3,
        in: db)
      return try TripIdea.find(pulled.id).fetchOne(db)!
    }

    #expect(entry.pinnedDate == commitmentStart)
    #expect(entry.status == .scheduled)
    #expect(entry.dayNumber == 3)
    #expect(entry.schedule == .timed(3, start: expectedStart, end: expectedEnd))
  }

  // ADR-0004/§4: sliding a dated trip's start date re-derives every pinned
  // stop's dayNumber so it keeps landing on the same real date; a normal
  // day-relative stop (no pin) never moves.
  @Test func updateSlidingStartDateRederivesPinnedStopsOnly() async throws {
    let originalStart = Date(timeIntervalSince1970: 1_700_000_000)
    let (pinnedDay, unpinnedDay) = try await database.write { db -> (Int?, Int?) in
      let trip = try Trip.create(
        name: "Copenhagen", certainty: .dated(start: originalStart), lengthInDays: 14, in: db)
      let pinnedIdea = try seedIdea(name: "Noma", in: db)
      let unpinnedIdea = try seedIdea(name: "Tivoli", in: db)
      let pinnedStop = try TripIdea.pull(ideaID: pinnedIdea.id, into: trip.id, in: db)
      let unpinnedStop = try TripIdea.pull(ideaID: unpinnedIdea.id, into: trip.id, in: db)
      // Pin the reservation to what's currently day 6; place the other stop on day 6 too.
      let pinnedDate = Calendar.current.date(byAdding: .day, value: 5, to: originalStart)!
      try TripIdea.setBooking(ReservationPin(date: pinnedDate), stopID: pinnedStop.id, in: db)
      try TripIdea.schedule(.day(6), ideaID: unpinnedIdea.id, tripID: trip.id, in: db)

      // Slide the start date two days later.
      let newStart = Calendar.current.date(byAdding: .day, value: 2, to: originalStart)!
      let draft = Trip.Draft(trip)
      try Trip.update(draft, certainty: .dated(start: newStart), in: db)

      let pinned = try TripIdea.find(pinnedStop.id).fetchOne(db)!
      let unpinned = try TripIdea.find(unpinnedStop.id).fetchOne(db)!
      return (pinned.dayNumber, unpinned.dayNumber)
    }
    // The pin's real date is now 2 days closer to the new start → day 4.
    #expect(pinnedDay == 4)
    // The unpinned stop's day-relative placement never moves.
    #expect(unpinnedDay == 6)
  }

  @Test func updateDatingAnUndatedTripRederivesItsExistingPins() async throws {
    let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let dayNumber = try await database.write { db -> Int? in
      let trip = try Trip.create(name: "Someday Denmark", lengthInDays: 10, in: db)  // undated
      let idea = try seedIdea(name: "Noma", in: db)
      let pulled = try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      // Pin while still undated — held inert (no dayNumber yet).
      try TripIdea.setBooking(ReservationPin(date: pinnedDate), stopID: pulled.id, in: db)
      #expect(try TripIdea.find(pulled.id).fetchOne(db)!.dayNumber == nil)

      // Certainty transitions someday → dated: the pin should become effective.
      let start = Calendar.current.date(byAdding: .day, value: -2, to: pinnedDate)!  // pin lands on day 3
      let draft = Trip.Draft(trip)
      try Trip.update(draft, certainty: .dated(start: start), in: db)
      return try TripIdea.find(pulled.id).fetchOne(db)!.dayNumber
    }
    #expect(dayNumber == 3)
  }

  @Test func updateWithoutAStartDateChangeLeavesPinnedStopsAlone() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let dayNumber = try await database.write { db -> Int? in
      let trip = try Trip.create(name: "Copenhagen", certainty: .dated(start: start), in: db)
      let idea = try seedIdea(name: "Noma", in: db)
      let pulled = try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      let pinnedDate = Calendar.current.date(byAdding: .day, value: 5, to: start)!
      try TripIdea.setBooking(ReservationPin(date: pinnedDate), stopID: pulled.id, in: db)
      // Update the trip's name only — same certainty/start date.
      var draft = Trip.Draft(trip)
      draft.name = "Copenhagen (renamed)"
      try Trip.update(draft, certainty: .dated(start: start), in: db)
      return try TripIdea.find(pulled.id).fetchOne(db)!.dayNumber
    }
    #expect(dayNumber == 6)  // unchanged — no re-derivation ran (no extra writes)
  }

  // MARK: - Freeform stops (ADR-0010)

  @Test func createFreeformBornScheduledInTheBucketWithNoIdea() async throws {
    let entry = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "Copenhagen", lengthInDays: 3, in: db)
      let id = try TripIdea.createFreeform(
        tripID: trip.id, title: "Lunch break", note: "Try the smørrebrød place", in: db)
      return try TripIdea.find(id).fetchOne(db)!
    }
    #expect(entry.ideaID == nil)
    #expect(entry.inlineTitle == "Lunch break")
    #expect(entry.inlineNote == "Try the smørrebrød place")
    // Born scheduled but unplaced — the To-Be-Scheduled bucket.
    #expect(entry.status == .scheduled)
    #expect(entry.schedule == .unscheduled)
  }

  @Test func createFreeformAppendsToTheBottomOfTheIntraDayOrder() async throws {
    let rank = try await database.write { db -> Int in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      // Two shortlisted ideas take ranks 0 and 1; a freeform stop should land at 2.
      for name in ["Tivoli", "Noma"] {
        let idea = try seedIdea(name: name, in: db)
        try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
        try TripIdea.setStatus(.shortlisted, ideaID: idea.id, tripID: trip.id, in: db)
      }
      let id = try TripIdea.createFreeform(tripID: trip.id, title: "Train to Aarhus", in: db)
      return try TripIdea.find(id).fetchOne(db)!.shortlistRank
    }
    #expect(rank == 2)
  }

  @Test func editFreeformUpdatesInlineContent() async throws {
    let entry = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let id = try TripIdea.createFreeform(tripID: trip.id, title: "Lunch", in: db)
      try TripIdea.editFreeform(stopID: id, title: "Late lunch", note: "1pm-ish", in: db)
      return try TripIdea.find(id).fetchOne(db)!
    }
    #expect(entry.inlineTitle == "Late lunch")
    #expect(entry.inlineNote == "1pm-ish")
  }

  @Test func editFreeformIsANoOpOnAnIdeaBackedStop() async throws {
    let entry = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "Copenhagen", in: db)
      let idea = try seedIdea(name: "Tivoli", in: db)
      let pulled = try TripIdea.pull(ideaID: idea.id, into: trip.id, in: db)
      // An idea-backed stop's content lives in the pool idea — editFreeform leaves it alone.
      try TripIdea.editFreeform(stopID: pulled.id, title: "Hijacked", note: "nope", in: db)
      return try TripIdea.find(pulled.id).fetchOne(db)!
    }
    #expect(entry.inlineTitle == nil)
    #expect(entry.inlineNote == nil)
    #expect(entry.ideaID != nil)
  }

  // MARK: - Helpers

  private func trip(_ name: String, _ certainty: Certainty) -> Trip {
    var trip = Trip(id: UUID(), name: name)
    trip.apply(certainty)
    return trip
  }

  private func seedIdea(name: String, in db: Database) throws -> Idea {
    let partyID = try TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try Idea.insert { Idea.Draft(id: id, name: name, travelPartyID: partyID) }.execute(db)
    return try Idea.find(id).fetchOne(db)!
  }
}
