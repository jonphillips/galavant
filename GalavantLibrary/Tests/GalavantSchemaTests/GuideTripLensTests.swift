import Foundation
import GalavantSchema
import Testing

@Suite struct GuideTripLensTests {
  let region = MapRegion(
    id: UUID(), name: "Val Serena", centerLatitude: 45, centerLongitude: 9,
    latitudeDelta: 2, longitudeDelta: 2)

  @Test func tripChoicePrefersValidChipPickThenScopeTripThenFirstCandidate() {
    let chip = UUID()
    let preferred = UUID()
    let first = UUID()
    let candidates = [
      GuideTripLens.TripChoice(id: first, name: "First"),
      GuideTripLens.TripChoice(id: preferred, name: "Preferred"),
      GuideTripLens.TripChoice(id: chip, name: "Chip pick"),
    ]
    #expect(GuideTripLens.chosenTripID(chipPick: chip, preferred: preferred, candidates: candidates) == chip)
    #expect(GuideTripLens.chosenTripID(chipPick: UUID(), preferred: preferred, candidates: candidates) == preferred)
    #expect(GuideTripLens.chosenTripID(chipPick: UUID(), preferred: UUID(), candidates: candidates) == first)
    #expect(GuideTripLens.chosenTripID(chipPick: nil, preferred: nil, candidates: []) == nil)
  }

  @Test func candidatesExcludeUnassignedAndCompletedTripsAndOrderDatedTargetedSomeday() {
    let calendar = Calendar(identifier: .gregorian)
    let now = date(2026, 11, 8, calendar: calendar)
    let dated = Trip(id: UUID(), name: "Dated", certaintyStage: .dated,
      startDate: date(2026, 11, 12, calendar: calendar), lengthInDays: 4)
    let targeted = Trip(id: UUID(), name: "Targeted", certaintyStage: .targeted, targetYear: 2027)
    let someday = Trip(id: UUID(), name: "Someday", somedayRank: 2)
    let completed = Trip(id: UUID(), name: "Completed", certaintyStage: .dated,
      startDate: date(2026, 10, 1, calendar: calendar), lengthInDays: 2)
    let unassigned = Trip(id: UUID(), name: "Unassigned", certaintyStage: .dated,
      startDate: date(2026, 11, 15, calendar: calendar))
    let trips = [someday, unassigned, completed, targeted, dated]
    let rows = [dated, targeted, someday, completed].map { trip in
      TripDayRegion(id: UUID(), tripID: trip.id, dayNumber: 1, regionID: region.id)
    } + [TripDayRegion(id: UUID(), tripID: unassigned.id, dayNumber: 1, regionID: UUID())]
    #expect(GuideTripLens.candidates(region: region, trips: trips, dayRegions: rows, now: now, calendar: calendar)
      .map(\.id) == [dated.id, targeted.id, someday.id])
  }

  @Test func mealSlotsCoverDaypartsTimedBoundariesAnytimeFoodAndIgnoreOtherKinds() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 2)
    let ideas = [
      idea("Lunch part"), idea("Lunch 12:30"), idea("Morning 09:00"), idea("Lunch 16:59"),
      idea("Dinner part"), idea("Dinner 19:30"), idea("Gelateria"), idea("Museum", kind: .museum),
      idea("Breakfast"),
    ]
    let schedules: [Schedule] = [
      .daypart(1, .lunch), .timed(1, start: "12:30", end: nil), .timed(1, start: "09:00", end: nil),
      .timed(1, start: "16:59", end: nil), .daypart(1, .dinner), .timed(1, start: "19:30", end: nil),
      .day(1), .day(1), .daypart(1, .breakfast),
    ]
    let entries = zip(ideas, schedules).map { idea, schedule in scheduledEntry(trip.id, idea: idea, schedule: schedule) }
    let lens = makeLens(trip: trip, ideas: ideas, entries: entries, dayNumbers: [1])
    guard case let .meals(days) = lens.body, let day = days.first else {
      Issue.record("Expected meal days")
      return
    }
    guard case let .filled(lunch) = day.lunch, case let .filled(dinner) = day.dinner else {
      Issue.record("Expected lunch and dinner slots")
      return
    }
    #expect(Set(lunch.map(\.title)) == Set(["Lunch part", "Lunch 12:30", "Morning 09:00", "Lunch 16:59"]))
    #expect(Set(dinner.map(\.title)) == Set(["Dinner part", "Dinner 19:30"]))
    #expect(day.alsoThatDay.map(\.title) == ["Gelateria"])
    #expect(lens.badges[ideas[0].id] == .meal(day: 1, .lunch, ringActive: nil))
    #expect(lens.badges[ideas[6].id] == .onTrip)
    #expect(lens.badges[ideas[7].id] == .onTrip)
    #expect(lens.badges[ideas[8].id] == .onTrip)
  }

  @Test func ringAppearsOnceAsActiveMemberAndEveryMemberGetsMealBadge() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 2)
    let ideas = [idea("One"), idea("Two"), idea("Three")]
    let groupID = UUID()
    let entries = ideas.enumerated().map { index, idea in
      var entry = scheduledEntry(trip.id, idea: idea, schedule: .daypart(1, .dinner))
      entry.alternativeGroupID = groupID
      entry.isActive = index == 1
      return entry
    }
    let group = TripAlternativeGroup(id: groupID, tripID: trip.id, label: "Options")
    let lens = makeLens(trip: trip, ideas: ideas, entries: entries, groups: [group], dayNumbers: [1])
    guard case let .meals(days) = lens.body, case let .filled(stops) = days[0].dinner else {
      Issue.record("Expected the ring in the dinner slot")
      return
    }
    #expect(stops.count == 1)
    #expect(stops[0].id == entries[1].id)
    #expect(stops[0].optionCount == 3)
    for (index, idea) in ideas.enumerated() {
      #expect(lens.badges[idea.id] == .meal(day: 1, .dinner, ringActive: index == 1))
    }
  }

  @Test func regionDaysFourThroughSevenProduceNightsFourThroughSix() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 7)
    let lens = makeLens(trip: trip, dayNumbers: [4, 5, 6, 7], category: .hotels)
    #expect(lens.body == .nights([.open(nights: 4...6)]))
  }

  @Test func stayRunIsClippedToRegionNightsAndBackToBackStaysRemainSeparate() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 7)
    let hotel = idea("Hotel", kind: .stay)
    let stay = TripStay(id: UUID(), tripID: trip.id, ideaID: hotel.id, checkInDay: 3, checkOutDay: 7)
    let lens = makeLens(trip: trip, ideas: [hotel], stays: [stay], dayNumbers: [4, 5, 6, 7], category: .hotels)
    #expect(lens.body == .nights([
      .stay(stayID: stay.id, ideaID: hotel.id, title: "Hotel", isBooked: false, nights: 4...6),
    ]))

    let shorterTrip = Trip(id: UUID(), name: "Short trip", lengthInDays: 6)
    let secondStay = TripStay.freeform(id: UUID(), tripID: shorterTrip.id, title: "Next hotel", checkInDay: 4, checkOutDay: 6)
    let firstStay = TripStay.freeform(id: UUID(), tripID: shorterTrip.id, title: "First hotel", checkInDay: 2, checkOutDay: 4)
    let backToBack = makeLens(trip: shorterTrip, stays: [firstStay, secondStay], dayNumbers: [2, 3, 4, 5], category: .hotels)
    #expect(backToBack.body == .nights([
      .stay(stayID: firstStay.id, ideaID: nil, title: "First hotel", isBooked: false, nights: 2...3),
      .stay(stayID: secondStay.id, ideaID: nil, title: "Next hotel", isBooked: false, nights: 4...5),
    ]))
  }

  @Test func datedAndUndatedRowsAndBadgeLabelsUseThePackageFormatting() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let saturday = date(2026, 11, 7, calendar: calendar)
    let dated = Trip(id: UUID(), name: "Dated", startDate: saturday, lengthInDays: 7)
    let dinnerIdea = idea("Dinner")
    let dinner = scheduledEntry(dated.id, idea: dinnerIdea, schedule: .daypart(5, .dinner))
    let onTripIdea = idea("Shortlisted")
    let shortlisted = TripIdea(id: UUID(), tripID: dated.id, ideaID: onTripIdea.id, status: .shortlisted)
    let hotel = idea("Hotel", kind: .stay)
    let stay = TripStay(id: UUID(), tripID: dated.id, ideaID: hotel.id, checkInDay: 3, checkOutDay: 7)
    let lens = makeLens(trip: dated, ideas: [dinnerIdea, onTripIdea, hotel], entries: [dinner, shortlisted],
      stays: [stay], dayNumbers: [5, 6, 7], category: .dining, calendar: calendar)
    guard case let .meals(days) = lens.body else {
      Issue.record("Expected meal days")
      return
    }
    #expect(days[0].date == dated.date(forDay: 5))
    #expect(days[0].weekday == .wednesday)
    #expect(lens.badgeLabel(for: dinnerIdea.id) == "Wed dinner")
    #expect(lens.badgeLabel(for: onTripIdea.id) == "On trip")
    #expect(lens.heading == "3 days in Val Serena")

    let undated = Trip(id: UUID(), name: "Someday", lengthInDays: 7)
    let undatedDinner = scheduledEntry(undated.id, idea: dinnerIdea, schedule: .daypart(5, .dinner))
    let undatedLens = makeLens(trip: undated, ideas: [dinnerIdea], entries: [undatedDinner], dayNumbers: [5])
    guard case let .meals(undatedDays) = undatedLens.body else {
      Issue.record("Expected undated meal days")
      return
    }
    #expect(undatedDays[0].weekday == nil)
    #expect(undatedDays[0].date == nil)
    #expect(undatedLens.badgeLabel(for: dinnerIdea.id) == "Day 5 dinner")
    #expect(undatedLens.heading == "Day 5 in Val Serena")

    let ringBadge = GuideTripLens.Badge.meal(day: 5, .dinner, ringActive: true)
    let ringLens = makeLens(trip: dated, ideas: [dinnerIdea], dayNumbers: [5])
    #expect(ringBadge.label(in: ringLens) == "Wed dinner · active")
    #expect(GuideTripLens.Badge.nights(4...6).label(in: ringLens) == "Nights 4–6")
    #expect(GuideTripLens.Badge.nights(4...4).label(in: ringLens) == "Night 4")
    #expect(GuideTripLens.Badge.onTrip.label(in: ringLens) == "On trip")
  }

  @Test func declinedAndDoneEntriesHaveNoBadges() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 2)
    let declinedIdea = idea("Declined")
    let doneIdea = idea("Done")
    let declined = TripIdea(id: UUID(), tripID: trip.id, ideaID: declinedIdea.id, status: .declined)
    let done = TripIdea(id: UUID(), tripID: trip.id, ideaID: doneIdea.id, status: .done)
    let lens = makeLens(trip: trip, ideas: [declinedIdea, doneIdea], entries: [declined, done], dayNumbers: [1])
    #expect(lens.badges[declinedIdea.id] == nil)
    #expect(lens.badges[doneIdea.id] == nil)
  }

  private func idea(_ name: String, kind: IdeaKind = .food) -> Idea {
    Idea(id: UUID(), name: name, kind: kind)
  }

  private func scheduledEntry(_ tripID: Trip.ID, idea: Idea, schedule: Schedule) -> TripIdea {
    var entry = TripIdea(id: UUID(), tripID: tripID, ideaID: idea.id, status: .scheduled)
    entry.apply(schedule)
    return entry
  }

  private func makeLens(
    trip: Trip, ideas: [Idea] = [], entries: [TripIdea] = [], stays: [TripStay] = [],
    groups: [TripAlternativeGroup] = [], dayNumbers: [Int], category: GuideCategory = .dining,
    calendar: Calendar = .current
  ) -> GuideTripLens {
    let dayRegions = dayNumbers.map {
      TripDayRegion(id: UUID(), tripID: trip.id, dayNumber: $0, regionID: region.id)
    }
    let plan = TripPlan(
      entries: entries, ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: trip.lengthInDays, tripStays: stays, dayRegions: dayRegions,
      alternativeGroups: groups)
    return GuideTripLens(
      trip: trip, candidates: [], region: region, category: category, plan: plan, calendar: calendar)
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
  }
}
