import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite struct ItineraryAlternativesTests {
  private func idea(_ id: Idea.ID, latitude: Double, longitude: Double) -> Idea {
    Idea(id: id, name: id.uuidString, latitude: latitude, longitude: longitude)
  }

  private func stop(
    _ id: TripIdea.ID = UUID(),
    ideaID: Idea.ID,
    rank: Int,
    dayRank: Double,
    groupID: UUID? = nil,
    isActive: Bool = true,
    schedule: Schedule = .day(1)
  ) -> TripIdea {
    var stop = TripIdea(
      id: id,
      tripID: UUID(),
      ideaID: ideaID,
      status: .scheduled,
      shortlistRank: rank,
      dayRank: dayRank,
      alternativeGroupID: groupID,
      isActive: isActive)
    stop.apply(schedule)
    return stop
  }

  private func plan(
    _ entries: [TripIdea],
    ideas: [Idea],
    alternativeGroups: [TripAlternativeGroup] = []
  ) -> TripPlan {
    TripPlan(
      entries: entries,
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: 2,
      alternativeGroups: alternativeGroups)
  }

  @Test func inactiveAlternativesNeverEnterTheRoutedSequence() {
    let (beforeID, activeID, inactiveID, afterID) = (UUID(), UUID(), UUID(), UUID())
    let groupID = UUID()
    let entries = [
      stop(ideaID: beforeID, rank: 0, dayRank: 0),
      stop(ideaID: activeID, rank: 1, dayRank: 1, groupID: groupID),
      stop(ideaID: inactiveID, rank: 2, dayRank: 1, groupID: groupID, isActive: false),
      stop(ideaID: afterID, rank: 3, dayRank: 2),
    ]
    let itinerary = plan(entries, ideas: [
      idea(beforeID, latitude: 0, longitude: 0),
      idea(activeID, latitude: 1, longitude: 1),
      idea(inactiveID, latitude: 2, longitude: 2),
      idea(afterID, latitude: 3, longitude: 3),
    ])

    #expect(itinerary.itinerary[0].stops.map(\.id) == [entries[0].id, entries[1].id, entries[3].id])
    #expect(itinerary.locatedSequenceNumbers(forDay: 1) == [
      entries[0].id: 1,
      entries[1].id: 2,
      entries[3].id: 3,
    ])
    #expect(itinerary.legs(forDay: 1).count == 2)
    #expect(itinerary.legs(forDay: 1).allSatisfy { leg in
      leg.fromLat != 1 || leg.toLat != 2
    })
  }

  @Test func effectiveWinnerUsesStoredActiveThenCanonicalOrder() {
    let (firstID, secondID, thirdID) = (UUID(), UUID(), UUID())
    let groupID = UUID()
    let first = stop(ideaID: firstID, rank: 0, dayRank: 0, groupID: groupID, isActive: false)
    var second = stop(ideaID: secondID, rank: 1, dayRank: 0, groupID: groupID, isActive: true)
    var third = stop(ideaID: thirdID, rank: 2, dayRank: 0, groupID: groupID, isActive: true)
    let ideas = [
      idea(firstID, latitude: 0, longitude: 0),
      idea(secondID, latitude: 1, longitude: 1),
      idea(thirdID, latitude: 2, longitude: 2),
    ]

    var itinerary = plan([first, second, third], ideas: ideas)
    #expect(itinerary.itinerary[0].stops.map(\.id) == [second.id])
    #expect(itinerary.alternatives(forStop: second.id)?.activeIndex == 1)

    second.isActive = false
    third.isActive = false
    itinerary = plan([first, second, third], ideas: ideas)
    #expect(itinerary.itinerary[0].stops.map(\.id) == [first.id])
    #expect(itinerary.alternatives(forStop: first.id)?.activeIndex == 0)
  }

  @Test func unresolvableStoredActiveFallsBackToTheFirstResolvablePeer() {
    let (orphanID, validID) = (UUID(), UUID())
    let groupID = UUID()
    let orphan = stop(ideaID: orphanID, rank: 0, dayRank: 0, groupID: groupID)
    let valid = stop(ideaID: validID, rank: 1, dayRank: 0, groupID: groupID, isActive: false)
    let itinerary = plan([orphan, valid], ideas: [idea(validID, latitude: 1, longitude: 1)])

    #expect(itinerary.itinerary[0].stops.map(\.id) == [valid.id])
    #expect(itinerary.scheduled.map(\.id) == [valid.id])
    #expect(itinerary.alternatives(forStop: valid.id) == nil)
  }

  @Test func toBeScheduledKeepsOneEffectiveRingMemberRecoverable() {
    let (firstID, secondID) = (UUID(), UUID())
    let groupID = UUID()
    let first = stop(
      ideaID: firstID, rank: 0, dayRank: 0, groupID: groupID,
      schedule: .unscheduled)
    let second = stop(
      ideaID: secondID, rank: 1, dayRank: 0, groupID: groupID,
      isActive: false, schedule: .unscheduled)
    let itinerary = plan([first, second], ideas: [
      idea(firstID, latitude: 0, longitude: 0),
      idea(secondID, latitude: 1, longitude: 1),
    ])

    #expect(itinerary.toBeScheduled.map(\.id) == [first.id])
    #expect(TripIdea.toBeScheduled([first, second]).map(\.id) == [first.id])
  }

  @Test func ordinaryStopsKeepTheirExistingProjection() {
    let (firstID, secondID) = (UUID(), UUID())
    let entries = [
      stop(ideaID: firstID, rank: 0, dayRank: 0),
      stop(ideaID: secondID, rank: 1, dayRank: 1),
    ]
    let itinerary = plan(entries, ideas: [
      idea(firstID, latitude: 0, longitude: 0),
      idea(secondID, latitude: 1, longitude: 1),
    ])

    #expect(TripIdea.effectiveActiveEntries(entries).map(\.id) == entries.map(\.id))
    #expect(itinerary.itinerary[0].stops.map(\.id) == entries.map(\.id))
    #expect(itinerary.legs(forDay: 1).count == 1)
  }

  @Test func alternativeGroupLabelJoinsIntoTheRingAndAbsentRowsStayUnlabeled() {
    let (firstID, secondID) = (UUID(), UUID())
    let groupID = UUID()
    let first = stop(ideaID: firstID, rank: 0, dayRank: 0, groupID: groupID)
    let second = stop(
      ideaID: secondID, rank: 1, dayRank: 0, groupID: groupID, isActive: false)
    let ideas = [
      idea(firstID, latitude: 0, longitude: 0),
      idea(secondID, latitude: 1, longitude: 1),
    ]

    let labeled = plan(
      [first, second],
      ideas: ideas,
      alternativeGroups: [TripAlternativeGroup(
        id: groupID, tripID: first.tripID, label: "Dinner Pregame Options")])
    #expect(labeled.alternatives(forStop: first.id)?.label == "Dinner Pregame Options")

    let unlabeled = plan([first, second], ideas: ideas)
    #expect(unlabeled.alternatives(forStop: first.id)?.label == nil)
  }
}

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct ItineraryAlternativeOperationTests {
  @Dependency(\.defaultDatabase) private var database

  private func insertRing(
    tripID: Trip.ID,
    groupID: UUID = UUID(),
    schedule: Schedule = .day(1),
    in db: Database
  ) throws -> [TripIdea] {
    let members = (0..<3).map { index -> TripIdea in
      var member = TripIdea(
        id: UUID(),
        tripID: tripID,
        ideaID: UUID(),
        status: .scheduled,
        shortlistRank: index,
        dayRank: Double(index),
        alternativeGroupID: groupID,
        isActive: index == 0)
      member.apply(schedule)
      return member
    }
    for member in members {
      try TripIdea.insert { TripIdea.Draft(member) }.execute(db)
    }
    return members
  }

  @Test func alternativeGroupLabelUpsertsAndReadsByRingID() async throws {
    let groupID = UUID()
    let tripID = try await database.write { db in
      try Trip.create(name: "Label", in: db).id
    }

    try await database.write { db in
      try TripAlternativeGroup.rename(
        groupID: groupID, tripID: tripID, label: "  Lunch  ", in: db)
    }
    let saved = try await database.read { db in
      try TripAlternativeGroup.find(groupID).fetchOne(db)
    }
    #expect(saved?.label == "Lunch")
    #expect(try await database.read { db in
      try TripAlternativeGroup.readLabel(for: groupID, in: db)
    } == "Lunch")

    try await database.write { db in
      try TripAlternativeGroup.rename(groupID: groupID, tripID: tripID, label: "Dinner", in: db)
    }
    #expect(try await database.read { db in
      try TripAlternativeGroup.readLabel(for: groupID, in: db)
    } == "Dinner")

    try await database.write { db in
      try TripAlternativeGroup.rename(groupID: groupID, tripID: tripID, label: " \n ", in: db)
    }
    #expect(try await database.read { db in
      try TripAlternativeGroup.readLabel(for: groupID, in: db)
    } == nil)
  }

  @Test func addCycleAndRemoveKeepOneStableSlot() async throws {
    let result = try await database.write { db -> (TripIdea, TripIdea, TripAlternativeGroup?) in
      let trip = try Trip.create(name: "Alternatives", in: db)
      var target = TripIdea(
        id: UUID(), tripID: trip.id, ideaID: UUID(), status: .scheduled,
        shortlistRank: 3, dayRank: 2)
      target.apply(.day(1))
      let source = TripIdea(
        id: UUID(), tripID: trip.id, ideaID: UUID(), status: .shortlisted,
        shortlistRank: 8, dayRank: 8)
      try TripIdea.insert { TripIdea.Draft(target) }.execute(db)
      try TripIdea.insert { TripIdea.Draft(source) }.execute(db)

      let groupID = UUID()
      try TripIdea.addAlternative(sourceStopID: source.id, to: target.id, groupID: groupID, in: db)
      try TripAlternativeGroup.rename(groupID: groupID, tripID: trip.id, label: "Lunch", in: db)
      let added = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      #expect(added.filter { $0.alternativeGroupID != nil }.count == 2)
      #expect(added.first(where: { $0.id == target.id })?.isActive == true)

      #expect(try TripIdea.cycleAlternative(stopID: target.id, in: db) == source.id)
      try TripIdea.remove(stopID: source.id, in: db)
      let survivor = try #require(try TripIdea.find(target.id).fetchOne(db))
      return (survivor, source, try TripAlternativeGroup.find(groupID).fetchOne(db))
    }
    #expect(result.0.status == .scheduled)
    #expect(result.0.schedule == .day(1))
    #expect(result.0.alternativeGroupID == nil)
    #expect(result.0.isActive)
    #expect(result.2 == nil)
  }

  @Test func unscheduleDissolvesEveryPeerIntoContiguousShortlist() async throws {
    let result = try await database.write { db -> ([TripIdea], TripAlternativeGroup?) in
      let trip = try Trip.create(name: "Unscheduled", in: db)
      let members = try insertRing(tripID: trip.id, in: db)
      let groupID = try #require(members.first?.alternativeGroupID)
      try TripAlternativeGroup.rename(groupID: groupID, tripID: trip.id, label: "Dinner", in: db)
      try TripIdea.unschedule(stopID: members[0].id, in: db)
      return (
        try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db),
        try TripAlternativeGroup.find(groupID).fetchOne(db))
    }
    let entries = result.0
    #expect(entries.map(\.status).allSatisfy { $0 == .shortlisted })
    #expect(entries.map(\.alternativeGroupID).allSatisfy { $0 == nil })
    #expect(entries.map(\.isActive).allSatisfy { $0 })
    #expect(entries.map(\.schedule).allSatisfy { $0 == .unscheduled })
    #expect(entries.map(\.shortlistRank).sorted() == [0, 1, 2])
    #expect(result.1 == nil)
  }

  @Test func skipAndDoneRemoveOnePeerAndKeepTheRing() async throws {
    let result = try await database.write { db -> ([TripIdea], [TripIdea]) in
      let skippedTrip = try Trip.create(name: "Skipped", in: db)
      let skipped = try insertRing(tripID: skippedTrip.id, in: db)
      try TripIdea.markSkipped(stopID: skipped[0].id, in: db)

      let doneTrip = try Trip.create(name: "Done", in: db)
      let done = try insertRing(tripID: doneTrip.id, in: db)
      try TripIdea.markDone(stopID: done[0].id, in: db)
      return (
        try TripIdea.where { $0.tripID.eq(skippedTrip.id) }.fetchAll(db),
        try TripIdea.where { $0.tripID.eq(doneTrip.id) }.fetchAll(db))
    }
    // Both terminals extract only the marked member and leave the rest a
    // scheduled ring-minus-one with exactly one effective active peer.
    let skipped = result.0
    #expect(skipped.first { $0.status == .skipped }?.alternativeGroupID == nil)
    let skipRemaining = skipped.filter { $0.status == .scheduled }
    #expect(skipRemaining.count == 2)
    #expect(skipRemaining.filter(\.isActive).count == 1)
    #expect(skipRemaining.allSatisfy { $0.alternativeGroupID != nil })

    let done = result.1
    #expect(done.first { $0.status == .done }?.alternativeGroupID == nil)
    let doneRemaining = done.filter { $0.status == .scheduled }
    #expect(doneRemaining.count == 2)
    #expect(doneRemaining.filter(\.isActive).count == 1)
    #expect(doneRemaining.allSatisfy { $0.alternativeGroupID != nil })
  }

  @Test func markingAnInactivePeerDoneLeavesTheActiveSlotIntact() async throws {
    let (activeID, entries) = try await database.write { db -> (TripIdea.ID, [TripIdea]) in
      let trip = try Trip.create(name: "Done inactive", in: db)
      let members = try insertRing(tripID: trip.id, in: db)  // members[0] is active
      try TripIdea.markDone(stopID: members[2].id, in: db)   // mark an inactive peer
      return (members[0].id, try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db))
    }
    // The active member keeps its day placement; only the inactive peer is done.
    #expect(entries.first { $0.status == .done }?.isActive == true)
    let remaining = entries.filter { $0.status == .scheduled }
    #expect(remaining.count == 2)
    let active = remaining.first { $0.id == activeID }
    #expect(active?.isActive == true)
    #expect(active?.dayNumber == 1)
    #expect(remaining.filter(\.isActive).count == 1)
  }

  @Test func promotionPlacesTheNewIndependentStopAfterItsFormerSlot() async throws {
    let entries = try await database.write { db -> [TripIdea] in
      let trip = try Trip.create(name: "Promote", in: db)
      let members = try insertRing(tripID: trip.id, in: db)
      try TripIdea.promoteAlternative(stopID: members[2].id, in: db)
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
    }
    let ordered = TripIdea.orderedDayStops(TripIdea.effectiveActiveEntries(entries))
    #expect(ordered.count == 2)
    #expect(ordered[1].alternativeGroupID == nil)
    #expect(ordered[0].dayRank < ordered[1].dayRank)
  }

  @Test func repeatedPromotionKeepsEveryFormerAlternativeInAStableOrder() async throws {
    let entries = try await database.write { db -> [TripIdea] in
      let trip = try Trip.create(name: "Promote twice", in: db)
      let members = try insertRing(tripID: trip.id, in: db)
      try TripIdea.promoteAlternative(stopID: members[1].id, in: db)
      try TripIdea.promoteAlternative(stopID: members[2].id, in: db)
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
    }
    let ordered = TripIdea.orderedDayStops(TripIdea.effectiveActiveEntries(entries))
    #expect(ordered.map(\.id).count == 3)
    #expect(ordered.map(\.alternativeGroupID).allSatisfy { $0 == nil })
    #expect(ordered.map(\.dayRank) == [0, 1, 2])
  }

  @Test func freeformAlternativeSharesPlacementWithoutLosingItsOwnContent() async throws {
    let entry = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "Freeform", in: db)
      let target = try insertRing(tripID: trip.id, in: db)[0]
      let freeformID = try #require(
        try TripIdea.addFreeformAlternative(title: "Picnic", note: "Pack cheese", to: target.id, in: db))
      return try #require(try TripIdea.find(freeformID).fetchOne(db))
    }
    #expect(entry.status == .scheduled)
    #expect(entry.schedule == .day(1))
    #expect(entry.inlineTitle == "Picnic")
    #expect(entry.inlineNote == "Pack cheese")
    #expect(!entry.isActive)
  }

  @Test func onlyTheActiveBookingMayMoveTheSharedSlot() async throws {
    let entries = try await database.write { db -> [TripIdea] in
      let start = Date(timeIntervalSince1970: 1_800_000_000)
      let trip = try Trip.create(name: "Booking", certainty: .dated(start: start), in: db)
      let members = try insertRing(tripID: trip.id, in: db)
      try TripIdea.setBooking(
        ReservationPin(date: start.addingTimeInterval(2 * 24 * 60 * 60)),
        stopID: members[0].id,
        in: db)
      try TripIdea.setBooking(
        ReservationPin(date: start.addingTimeInterval(4 * 24 * 60 * 60)),
        stopID: members[1].id,
        in: db)
      return try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)
    }
    #expect(entries.map(\.dayNumber).allSatisfy { $0 == 3 })
    #expect(entries.first(where: { !$0.isActive })?.pinnedDate != nil)
  }

  @Test func slotWritersPropagateOnlyTheActiveCalendarMember() async throws {
    let result = try await database.write { db -> ([TripIdea], [TripIdea]) in
      let trip = try Trip.create(name: "Calendar", in: db)
      let members = try insertRing(tripID: trip.id, in: db)
      try TripIdea.schedule(.timed(2, start: "10:00", end: "11:00"), stopID: members[1].id, in: db)
      try TripIdea.reorderDayStops([members[0].id], in: db)
      let afterManualWriters = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db)

      let start = Date(timeIntervalSince1970: 1_800_000_000)
      try TripIdea.applyCalendarCommitment(
        .timed(start: start, end: start.addingTimeInterval(60 * 60)),
        stopID: members[1].id,
        dayNumber: 3,
        in: db)
      try TripIdea.applyCalendarCommitment(
        .timed(start: start, end: start.addingTimeInterval(60 * 60)),
        stopID: members[0].id,
        dayNumber: 3,
        in: db)
      return (afterManualWriters, try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db))
    }
    #expect(result.0.map(\.schedule).allSatisfy { $0 == .timed(2, start: "10:00", end: "11:00") })
    #expect(result.0.map(\.dayRank).allSatisfy { $0 == 0 })
    #expect(result.1.map(\.dayNumber).allSatisfy { $0 == 3 })
  }
}
