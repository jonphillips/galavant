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
      idea("Lunch part"), idea("Lunch 11:00"), idea("Lunch 12:30"), idea("Before lunch 10:59"),
      idea("Lunch 16:59"), idea("Dinner part"), idea("Dinner 17:00"), idea("Dinner 19:30"),
      idea("Gelateria"), idea("Museum", kind: .museum), idea("Breakfast"),
    ]
    let schedules: [Schedule] = [
      .daypart(1, .lunch), .timed(1, start: "11:00", end: nil), .timed(1, start: "12:30", end: nil),
      .timed(1, start: "10:59", end: nil), .timed(1, start: "16:59", end: nil),
      .daypart(1, .dinner), .timed(1, start: "17:00", end: nil), .timed(1, start: "19:30", end: nil),
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
    #expect(Set(lunch.map(\.title)) == Set(["Lunch part", "Lunch 11:00", "Lunch 12:30", "Lunch 16:59"]))
    #expect(Set(dinner.map(\.title)) == Set(["Dinner part", "Dinner 17:00", "Dinner 19:30"]))
    #expect(day.alsoThatDay.map(\.title) == ["Gelateria"])
    #expect(lens.badges[ideas[0].id] == .meal(day: 1, .lunch, ringActive: nil))
    #expect(lens.badges[ideas[3].id] == .onTrip)
    #expect(lens.badges[ideas[8].id] == .onTrip)
    #expect(lens.badges[ideas[9].id] == .onTrip)
    #expect(lens.badges[ideas[10].id] == .onTrip)
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

  @Test func mealDaysCarryTheirDaySummary() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 2)
    let notes = [TripDayNote(tripID: trip.id, dayNumber: 1, note: "Market and concert")]
    let plan = TripPlan(
      entries: [], ideasByID: [:], lengthInDays: trip.lengthInDays,
      dayRegions: [
        TripDayRegion(id: UUID(), tripID: trip.id, dayNumber: 1, regionID: region.id),
        TripDayRegion(id: UUID(), tripID: trip.id, dayNumber: 2, regionID: region.id),
      ])
    let lens = GuideTripLens(
      trip: trip, candidates: [], region: region, category: .dining,
      plan: plan, dayNotes: notes, calendar: .current)

    guard case let .meals(days) = lens.body else {
      Issue.record("Expected meal days")
      return
    }
    #expect(days.map(\.summary) == ["Market and concert", nil])
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

  @Test func guideMenuOffersOpenSlotOptionAndShortlistAndChecksCurrentSlot() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 2)
    let targetIdea = idea("Target")
    let candidate = idea("Candidate")
    let target = scheduledEntry(trip.id, idea: targetIdea, schedule: .daypart(1, .dinner))
    let lens = makeLens(trip: trip, ideas: [targetIdea], entries: [target], dayNumbers: [1])
    let menu = GuideSlotMenu(lens: lens, idea: candidate, entries: [target], stays: [], calendar: .current)

    #expect(menu.sections.count == 2)
    #expect(menu.sections[0][0].action == .schedule(day: 1, .lunch))
    #expect(menu.sections[0][1].action == .addOption(to: target.id))
    #expect(menu.sections[0][1].detail == "Add as an option to Target")
    #expect(menu.sections[1][0].action == .shortlist)

    let currentMenu = GuideSlotMenu(lens: lens, idea: targetIdea, entries: [target], stays: [], calendar: .current)
    #expect(currentMenu.sections[0][1].isCurrent)
    #expect(currentMenu.sections[0][1].action == nil)
    #expect(currentMenu.sections[0][1].detail == "Already on Day 1 dinner")
    #expect(currentMenu.sections[1][0].isCurrent == false)
  }

  @Test func guideMenuExplainsWholeDayAndMealOnlyClosures() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let trip = Trip(id: UUID(), name: "Dated", startDate: date(2026, 11, 9, calendar: calendar), lengthInDays: 2)
    let closed = idea("Closed")
    var closedIdea = closed
    closedIdea.structuredHours = WeeklyHours(days: [.closed] + Array(repeating: .unknown, count: 6)).encoded()
    let lunchOnly = idea("Lunch only")
    var lunchIdea = lunchOnly
    lunchIdea.structuredHours = WeeklyHours(days: [.open([ServicePeriod(meal: .lunch)])]
      + Array(repeating: .unknown, count: 6)).encoded()

    let closedLens = makeLens(trip: trip, dayNumbers: [1], calendar: calendar)
    let closedMenu = GuideSlotMenu(lens: closedLens, idea: closedIdea, entries: [], stays: [], calendar: calendar)
    #expect(closedMenu.sections[0][0].detail == "Closed Mondays")
    #expect(closedMenu.sections[0][0].action == nil)
    let lunchMenu = GuideSlotMenu(lens: closedLens, idea: lunchIdea, entries: [], stays: [], calendar: calendar)
    #expect(lunchMenu.sections[0][1].detail == "No dinner on Mondays")
    #expect(lunchMenu.sections[0][1].action == nil)
  }

  @Test func guideMenuAllowsClosedHoursOnAnUndatedTrip() {
    let trip = Trip(id: UUID(), name: "Undated", lengthInDays: 1)
    var closedIdea = idea("Closed")
    closedIdea.structuredHours = WeeklyHours(days: Array(repeating: .closed, count: 7)).encoded()
    let lens = makeLens(trip: trip, dayNumbers: [1])
    let menu = GuideSlotMenu(lens: lens, idea: closedIdea, entries: [], stays: [], calendar: .current)
    #expect(menu.sections[0][0].detail == "Open slot")
    #expect(menu.sections[0][0].action == .schedule(day: 1, .lunch))
  }

  @Test func hotelMenuChecksItsStayAndPreventsAddingTheSameHotelAgain() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 4)
    let hotel = idea("Hotel", kind: .stay)
    let stay = TripStay(id: UUID(), tripID: trip.id, ideaID: hotel.id, checkInDay: 1, checkOutDay: 3)
    let lens = makeLens(trip: trip, ideas: [hotel], stays: [stay], dayNumbers: [1, 2, 3], category: .hotels)
    let currentMenu = GuideSlotMenu(lens: lens, idea: hotel, entries: [], stays: [stay], calendar: .current)
    #expect(currentMenu.sections[0][0].isCurrent)
    #expect(currentMenu.sections[0][0].action == nil)
    #expect(currentMenu.sections[1][0].action == nil)

    let candidate = idea("Another hotel", kind: .stay)
    let candidateMenu = GuideSlotMenu(lens: lens, idea: candidate, entries: [], stays: [stay], calendar: .current)
    #expect(candidateMenu.sections[1][0].action == .stay(nights: 3...3))
  }

  @Test func disabledRowsNameTheStopLocationInsteadOfTheMenuRow() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 3)
    let currentIdea = idea("Current")
    let firstTarget = idea("Lunch target")
    let laterTarget = idea("Later target")
    let current = scheduledEntry(trip.id, idea: currentIdea, schedule: .daypart(2, .dinner))
    let first = scheduledEntry(trip.id, idea: firstTarget, schedule: .daypart(1, .lunch))
    let later = scheduledEntry(trip.id, idea: laterTarget, schedule: .daypart(3, .lunch))
    let lens = makeLens(trip: trip, ideas: [currentIdea, firstTarget, laterTarget],
      entries: [current, first, later], dayNumbers: [1, 2, 3])
    let menu = GuideSlotMenu(lens: lens, idea: currentIdea, entries: [current, first, later], stays: [], calendar: .current)
    #expect(menu.sections[0][0].detail == "Already on Day 2 dinner")
    #expect(menu.sections[0][0].isCurrent == false)
    #expect(menu.sections[1][1].detail == "Already on Day 2 dinner")
    #expect(menu.sections[1][1].isCurrent)
    #expect(menu.sections[2][0].detail == "Already on Day 2 dinner")
    #expect(menu.sections[2][0].action == nil)
  }

  @Test func scheduledLoneStopCanMoveToOpenSlotsButRingMembersAreDisabled() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 3)
    let currentIdea = idea("Current")
    let targetIdea = idea("Target")
    let current = scheduledEntry(trip.id, idea: currentIdea, schedule: .daypart(2, .dinner))
    let target = scheduledEntry(trip.id, idea: targetIdea, schedule: .daypart(3, .lunch))
    let lens = makeLens(trip: trip, ideas: [currentIdea, targetIdea], entries: [current, target], dayNumbers: [1, 2, 3])
    let menu = GuideSlotMenu(lens: lens, idea: currentIdea, entries: [current, target], stays: [], calendar: .current)
    #expect(menu.sections[0][0].action == .move(stopID: current.id, day: 1, .lunch))
    #expect(menu.sections[1][1].isCurrent)
    #expect(menu.sections[1][1].action == nil)
    #expect(menu.sections[2][0].detail == "Already on Day 2 dinner")
    #expect(menu.sections[2][0].action == nil)
    #expect(menu.sections[3][0].action == nil)

    let groupID = UUID()
    var ringMember = current
    ringMember.alternativeGroupID = groupID
    ringMember.isActive = false
    var ringTarget = scheduledEntry(trip.id, idea: targetIdea, schedule: .daypart(2, .dinner))
    ringTarget.alternativeGroupID = groupID
    let ringLens = makeLens(trip: trip, ideas: [currentIdea, targetIdea], entries: [ringMember, ringTarget],
      groups: [TripAlternativeGroup(id: groupID, tripID: trip.id, label: "Dinner")], dayNumbers: [1, 2, 3])
    let ringMenu = GuideSlotMenu(lens: ringLens, idea: currentIdea, entries: [ringMember, ringTarget], stays: [], calendar: .current)
    #expect(ringMenu.sections[0][0].action == nil)
    #expect(ringMenu.sections[0][0].detail == "One of the options for Day 2 dinner")
    #expect(ringMenu.sections[1][1].isCurrent)
    #expect(ringMenu.sections[1][1].action == nil)
    #expect(ringMenu.sections[3][0].action == nil)
  }

  @Test func doneAndSkippedIdeasStayDisabledWithTheirOriginalSlot() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 2)
    for (status, reason) in [(TripIdeaStatus.done, "Done"), (.skipped, "Skipped")] {
      let idea = self.idea(reason)
      var entry = scheduledEntry(trip.id, idea: idea, schedule: .daypart(1, .dinner))
      entry.status = status
      let lens = makeLens(trip: trip, ideas: [idea], entries: [entry], dayNumbers: [1, 2])
      let menu = GuideSlotMenu(lens: lens, idea: idea, entries: [entry], stays: [], calendar: .current)
      #expect(menu.sections.flatMap { $0 }.allSatisfy { $0.action == nil && $0.detail == "\(reason) on Day 1 dinner" })
      #expect(menu.sections[0][1].isCurrent)
    }
  }

  @Test func focusedSlotProjectsRingOrderAndOpenCandidates() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let datedTrip = Trip(id: UUID(), name: "Dated", startDate: date(2026, 11, 9, calendar: calendar), lengthInDays: 2)
    let closedIdea = idea("Closed")
    var closed = closedIdea
    closed.structuredHours = WeeklyHours(days: [.closed] + Array(repeating: .unknown, count: 6)).encoded()
    let unknown = idea("Unknown")
    let openLens = makeLens(trip: datedTrip, dayNumbers: [1], calendar: calendar)
    let datedFocus = GuideSlotFocus(day: 1, meal: .lunch, lens: openLens, entries: [], ideas: [closed, unknown])
    #expect(datedFocus?.content == .open(ideaIDs: [unknown.id]))

    let undatedTrip = Trip(id: UUID(), name: "Undated", lengthInDays: 2)
    let undatedLens = makeLens(trip: undatedTrip, dayNumbers: [1])
    let undatedFocus = GuideSlotFocus(day: 1, meal: .lunch, lens: undatedLens, entries: [], ideas: [closed, unknown])
    #expect(undatedFocus?.content == .open(ideaIDs: [closed.id, unknown.id]))

    let first = idea("First option")
    let second = idea("Second option")
    let freeform = TripIdea.freeform(id: UUID(), tripID: undatedTrip.id, title: "Picnic", shortlistRank: 3)
    var firstEntry = scheduledEntry(undatedTrip.id, idea: first, schedule: .daypart(1, .dinner))
    firstEntry.alternativeGroupID = UUID()
    firstEntry.shortlistRank = 1
    firstEntry.isActive = true
    firstEntry.dayRank = 0
    var secondEntry = scheduledEntry(undatedTrip.id, idea: second, schedule: .daypart(1, .dinner))
    secondEntry.alternativeGroupID = firstEntry.alternativeGroupID
    secondEntry.shortlistRank = 2
    secondEntry.isActive = false
    secondEntry.dayRank = 0
    var picnic = freeform
    picnic.apply(.daypart(1, .dinner))
    picnic.dayRank = 1
    let group = TripAlternativeGroup(id: firstEntry.alternativeGroupID!, tripID: undatedTrip.id, label: "Dinner")
    let filledLens = makeLens(trip: undatedTrip, ideas: [first, second], entries: [firstEntry, secondEntry, picnic],
      groups: [group], dayNumbers: [1])
    let focused = GuideSlotFocus(day: 1, meal: .dinner, lens: filledLens,
      entries: [firstEntry, secondEntry, picnic], ideas: [first, second])
    guard case let .filled(stops)? = focused?.content else {
      Issue.record("Expected focused meal options")
      return
    }
    #expect(stops.map(\.title) == ["First option", "Second option", "Picnic"])
    #expect(stops.map(\.isActive) == [true, false, true])
    #expect(focused?.title == "Showing options for Day 1 dinner")
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
