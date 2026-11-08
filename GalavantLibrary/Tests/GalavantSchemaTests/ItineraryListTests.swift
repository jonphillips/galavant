import Foundation
import GalavantSchema
import Testing

@Suite struct ItineraryListTests {
  private func stop(
    id: UUID = UUID(), tripID: Trip.ID, ideaID: UUID,
    schedule: Schedule, rank: Int = 0, groupID: UUID? = nil, active: Bool = true,
    status: TripIdeaStatus? = nil,
    latitude: Double? = 40, longitude: Double? = 11
  ) -> (TripIdea, Idea) {
    var entry = TripIdea(
      id: id, tripID: tripID, ideaID: ideaID,
      status: status ?? (schedule == .unscheduled ? .shortlisted : .scheduled),
      shortlistRank: rank, dayRank: Double(rank), alternativeGroupID: groupID, isActive: active)
    entry.apply(schedule)
    return (entry, Idea(id: ideaID, name: "Stop \(rank)", latitude: latitude, longitude: longitude))
  }

  @Test func largeListDerivesSharedInputsOnceForWholeTripAndFocusedDay() {
    let tripID = UUID()
    var entries: [TripIdea] = []
    var ideas: [Idea] = []
    for day in 1...40 {
      for rank in 0..<6 {
        let (entry, idea) = stop(tripID: tripID, ideaID: UUID(), schedule: .day(day), rank: rank)
        entries.append(entry)
        ideas.append(idea)
      }
    }
    let plan = TripPlan(entries: entries, ideasByID: Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0) }), lengthInDays: 40)
    var stopCalls = 0
    var stayCalls = 0
    var ringCalls = 0
    let whole = plan.itineraryList(
      focusedDay: nil, overrides: [:], mainMode: nil, travelTimes: [:],
      autoSwitchThreshold: 1_200, now: nil, tripStartDate: nil,
      resolvedStops: { stopCalls += 1; return plan.effectiveResolvedStops },
      resolvedStays: { stayCalls += 1; return plan.stays },
      rings: { ringCalls += 1; return plan.resolvedRingsByStop })
    #expect(whole.days.count == 40)
    #expect(whole.days.reduce(0) { $0 + $1.stops.count } == 240)
    #expect(stopCalls == 1)
    #expect(stayCalls == 1)
    #expect(ringCalls == 1)

    stopCalls = 0
    stayCalls = 0
    ringCalls = 0
    let focused = plan.itineraryList(
      focusedDay: 55, overrides: [:], mainMode: nil, travelTimes: [:],
      autoSwitchThreshold: 1_200, now: nil, tripStartDate: nil,
      resolvedStops: { stopCalls += 1; return plan.effectiveResolvedStops },
      resolvedStays: { stayCalls += 1; return plan.stays },
      rings: { ringCalls += 1; return plan.resolvedRingsByStop })
    #expect(focused.days.map(\.number) == [55])
    #expect(stopCalls == 1)
    #expect(stayCalls == 1)
    #expect(ringCalls == 1)
  }

  @Test func sharedItineraryListMatchesExistingPublicProjections() throws {
    let tripID = UUID()
    let (before, beforeIdea) = stop(tripID: tripID, ideaID: UUID(), schedule: .day(1), rank: 0)
    let (unlocated, unlocatedIdea) = stop(
      tripID: tripID, ideaID: UUID(), schedule: .timed(1, start: "10:00", end: nil), rank: 1,
      latitude: nil, longitude: nil)
    let groupID = UUID()
    let (winner, winnerIdea) = stop(
      tripID: tripID, ideaID: UUID(), schedule: .daypart(2, .lunch), rank: 2,
      groupID: groupID, active: true)
    let (alternative, alternativeIdea) = stop(
      tripID: tripID, ideaID: UUID(), schedule: .daypart(2, .lunch), rank: 3,
      groupID: groupID, active: false)
    let (unscheduled, unscheduledIdea) = stop(
      tripID: tripID, ideaID: UUID(), schedule: .unscheduled, rank: 4)
    let (toBeScheduled, toBeScheduledIdea) = stop(
      tripID: tripID, ideaID: UUID(), schedule: .unscheduled, rank: 5, status: .scheduled)
    let entries = [before, unlocated, winner, alternative, unscheduled, toBeScheduled]
    let ideas = [beforeIdea, unlocatedIdea, winnerIdea, alternativeIdea, unscheduledIdea, toBeScheduledIdea]
    let start = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 7))!
    let hotel1ID = UUID()
    let hotel2ID = UUID()
    let hotel3ID = UUID()
    let hotelIdeas = [
      Idea(id: hotel1ID, name: "First", kind: .stay, latitude: 39, longitude: 10),
      Idea(id: hotel2ID, name: "Second", kind: .stay, latitude: 42, longitude: 12),
      Idea(id: hotel3ID, name: "Overlap", kind: .stay, latitude: 43, longitude: 13),
    ]
    let stay1 = TripStay(id: UUID(), tripID: tripID, ideaID: hotel1ID, checkInDay: 1, checkOutDay: 2)
    let stay2 = TripStay(id: UUID(), tripID: tripID, ideaID: hotel2ID, checkInDay: 2, checkOutDay: 3)
    let stay3 = TripStay(id: UUID(), tripID: tripID, ideaID: hotel3ID, checkInDay: 1, checkOutDay: 3)
    let commitment = CalendarCommitment(
      temporal: .absolute(
        start: start.addingTimeInterval(9 * 60 * 60), end: start.addingTimeInterval(10 * 60 * 60),
        timeZone: TimeZone(secondsFromGMT: 0)!),
      availability: .busy)!
    let constraint = CalendarTripConstraint(
      id: UUID(), tripID: tripID, sourceIdentityHash: "calendar", title: "Appointment",
      dayNumber: 1, startTime: "09:00", endTime: "10:00", commitment: commitment)!
    let plan = TripPlan(
      entries: entries,
      ideasByID: Dictionary(uniqueKeysWithValues: (ideas + hotelIdeas).map { ($0.id, $0) }),
      lengthInDays: 3, tripStays: [stay1, stay2, stay3], calendarConstraints: [constraint],
      alternativeGroups: [TripAlternativeGroup(id: groupID, tripID: tripID, label: "Options")])
    let list = plan.itineraryList(
      focusedDay: nil, overrides: [:], mainMode: nil, travelTimes: [:],
      autoSwitchThreshold: 1_200, now: start.addingTimeInterval(12 * 60 * 60), tripStartDate: start)
    let modes = plan.legModes(
      overrides: [:], mainMode: nil, travelTimes: [:], autoSwitchThreshold: 1_200)

    #expect(list.overlappingStayIDs == plan.overlappingStayIDs)
    #expect(list.toBeScheduled.map(\.id) == plan.toBeScheduled.map(\.id))
    #expect(list.toBeScheduled.contains { $0.id == toBeScheduled.id })
    #expect(list.days.count == plan.itinerary.count)
    for day in plan.itinerary {
      let projected = try #require(list.days.first { $0.number == day.number })
      #expect(projected.items == plan.itineraryItems(
        forDay: day.number, travelTimes: [:], effectiveModes: modes,
        now: start.addingTimeInterval(12 * 60 * 60), tripStartDate: start,
        stays: plan.stays(coveringDay: day.number)))
      #expect(projected.sequence == plan.locatedSequenceNumbers(forDay: day.number))
    }
    for entry in entries {
      #expect(list.facts(forStop: entry.id).ring == plan.alternatives(forStop: entry.id))
    }
    #expect(list.days[0].items.contains(.nowMarker))
    #expect(list.days[0].items.contains { if case .calendarConstraint = $0 { true } else { false } })
  }

  @Test func coordinateCollisionKeepsFirstLegIdentityForModes() throws {
    let tripID = UUID()
    let coordinates = [(40.0, 11.0), (41.0, 12.0), (40.0, 11.0), (41.0, 12.0)]
    let stops = coordinates.enumerated().map { index, coordinate in
      stop(
        tripID: tripID, ideaID: UUID(), schedule: .day(1), rank: index,
        latitude: coordinate.0, longitude: coordinate.1)
    }
    let entries = stops.map(\.0)
    let ideas = stops.map(\.1)
    let plan = TripPlan(
      entries: entries, ideasByID: Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0) }),
      lengthInDays: 1)
    let pairs = plan.allLegPairs(itinerary: { plan.itinerary }, stays: { plan.stays })
    let duplicate = try #require(pairs.first { first in
      pairs.dropFirst().contains { $0.leg == first.leg && $0.identity != first.identity }
    })
    let collisionPairs = pairs.filter { $0.leg == duplicate.leg }
    #expect(collisionPairs.count == 2)
    #expect(collisionPairs[0].identity != collisionPairs[1].identity)
    let autoPair = try #require(pairs.first { $0.leg != duplicate.leg })
    let overrides = [collisionPairs[0].identity: TransportMode.transit]
    let travelTimes: [LegKey: [TransportMode: TravelTime]] = [
      duplicate.leg: [.walking: TravelTime(seconds: 60, meters: 80)],
      autoPair.leg: [.walking: TravelTime(seconds: 1_500, meters: 2_000)],
    ]
    let threshold = 1_200.0
    let list = plan.itineraryList(
      focusedDay: nil, overrides: overrides, mainMode: nil, travelTimes: travelTimes,
      autoSwitchThreshold: threshold, now: nil, tripStartDate: nil)
    let expectedModes = plan.legModes(
      overrides: overrides, mainMode: nil, travelTimes: travelTimes,
      autoSwitchThreshold: threshold)
    let connectors = list.days.flatMap(\.items).compactMap { item -> TravelConnector? in
      guard case let .connector(connector) = item else { return nil }
      return connector
    }

    #expect(expectedModes[duplicate.leg] == .transit)
    #expect(expectedModes[autoPair.leg] == .transit)
    #expect(connectors.first { $0.leg == duplicate.leg }?.mode == expectedModes[duplicate.leg])
    #expect(connectors.first { $0.leg == autoPair.leg }?.mode == expectedModes[autoPair.leg])
  }

  @Test func moveFactsRespectAnytimeOrderAndExcludedRows() {
    let tripID = UUID()
    let groupID = UUID()
    let (first, firstIdea) = stop(tripID: tripID, ideaID: UUID(), schedule: .day(1), rank: 0)
    let (timed, timedIdea) = stop(tripID: tripID, ideaID: UUID(), schedule: .timed(1, start: "09:00", end: nil), rank: 1)
    let (middle, middleIdea) = stop(tripID: tripID, ideaID: UUID(), schedule: .day(1), rank: 2)
    let (daypart, daypartIdea) = stop(tripID: tripID, ideaID: UUID(), schedule: .daypart(1, .lunch), rank: 3)
    let (last, lastIdea) = stop(tripID: tripID, ideaID: UUID(), schedule: .day(1), rank: 4)
    let (single, singleIdea) = stop(tripID: tripID, ideaID: UUID(), schedule: .day(2), rank: 0)
    let (winner, winnerIdea) = stop(tripID: tripID, ideaID: UUID(), schedule: .day(3), rank: 0, groupID: groupID)
    let (other, otherIdea) = stop(tripID: tripID, ideaID: UUID(), schedule: .day(3), rank: 1, groupID: groupID, active: false)
    let (unscheduled, unscheduledIdea) = stop(tripID: tripID, ideaID: UUID(), schedule: .unscheduled, rank: 0)
    let entries = [first, timed, middle, daypart, last, single, winner, other, unscheduled]
    let ideas = [firstIdea, timedIdea, middleIdea, daypartIdea, lastIdea, singleIdea, winnerIdea, otherIdea, unscheduledIdea]
    let plan = TripPlan(entries: entries, ideasByID: Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0) }), lengthInDays: 3)
    let list = plan.itineraryList(
      focusedDay: nil, overrides: [:], mainMode: nil, travelTimes: [:],
      autoSwitchThreshold: 1_200, now: nil, tripStartDate: nil)

    let dayStops = list.days[0].stops
    let anytimeStops = dayStops.enumerated().filter {
      if case .day = $0.element.entry.schedule { true } else { false }
    }
    #expect(anytimeStops.count == 3)
    for (index, stop) in anytimeStops {
      #expect(list.facts(forStop: stop.id).canMoveEarlier == (index > 0))
      #expect(list.facts(forStop: stop.id).canMoveLater == (index + 1 < dayStops.count))
    }
    #expect(list.facts(forStop: timed.id).canMoveEarlier == false)
    #expect(list.facts(forStop: timed.id).canMoveLater == false)
    #expect(list.facts(forStop: daypart.id).canMoveEarlier == false)
    #expect(list.facts(forStop: daypart.id).canMoveLater == false)
    #expect(list.facts(forStop: single.id).canMoveEarlier == false)
    #expect(list.facts(forStop: single.id).canMoveLater == false)
    #expect(list.facts(forStop: winner.id).ring != nil)
    #expect(list.facts(forStop: other.id).ring != nil)
    #expect(list.facts(forStop: other.id).canMoveEarlier == false)
    #expect(list.facts(forStop: unscheduled.id).canMoveLater == false)
  }
}
