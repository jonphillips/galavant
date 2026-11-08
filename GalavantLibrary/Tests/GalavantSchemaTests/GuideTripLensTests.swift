import Foundation
import GalavantSchema
import Testing

@Suite struct GuideTripLensTests {
  let region = MapRegion(
    id: UUID(), name: "Val Serena", centerLatitude: 45, centerLongitude: 9,
    latitudeDelta: 2, longitudeDelta: 2)

  @Test func tripChoiceUsesPreferredThenFirstThenLastPick() {
    let preferred = UUID()
    let first = UUID()
    let last = UUID()
    let candidates = [
      GuideTripLens.TripChoice(id: first, name: "First"),
      GuideTripLens.TripChoice(id: preferred, name: "Preferred"),
    ]
    #expect(GuideTripLens.chosenTripID(preferred: preferred, candidates: candidates, lastPicked: last) == preferred)
    #expect(GuideTripLens.chosenTripID(preferred: last, candidates: candidates, lastPicked: last) == first)
    #expect(GuideTripLens.chosenTripID(preferred: nil, candidates: [], lastPicked: last) == last)
  }

  @Test func mealSlotsIncludeDaypartsAndClockTimesAndKeepAnytimeFood() {
    let trip = Trip(id: UUID(), name: "Italy", startDate: Date(timeIntervalSince1970: 1_800_000_000), lengthInDays: 2)
    let lunch = Idea(id: UUID(), name: "Lunch", kind: .food)
    let dinner = Idea(id: UUID(), name: "Dinner", kind: .food)
    let anytime = Idea(id: UUID(), name: "Gelateria", kind: .food)
    let museum = Idea(id: UUID(), name: "Museum", kind: .museum)
    let breakfast = Idea(id: UUID(), name: "Breakfast", kind: .food)
    let ideas = [lunch, dinner, anytime, museum, breakfast]
    let entries = [lunch, dinner, anytime, museum, breakfast].enumerated().map { index, idea in
      var entry = TripIdea(id: UUID(), tripID: trip.id, ideaID: idea.id, status: .scheduled)
      switch index {
      case 0: entry.apply(.daypart(1, .lunch))
      case 1: entry.apply(.timed(1, start: "19:30", end: nil))
      case 2: entry.apply(.day(1))
      case 3: entry.apply(.day(1))
      default: entry.apply(.daypart(1, .breakfast))
      }
      return entry
    }
    let regions = [TripDayRegion(id: UUID(), tripID: trip.id, dayNumber: 1, regionID: region.id)]
    let plan = TripPlan(entries: entries, ideasByID: Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0) }),
      lengthInDays: trip.lengthInDays, dayRegions: regions)
    let lens = GuideTripLens(trip: trip, candidates: [], region: region, category: .dining, plan: plan, calendar: .current)
    guard case let .meals(days) = lens.body, let day = days.first else {
      Issue.record("Expected meal days")
      return
    }
    guard case let .filled(lunchStops) = day.lunch, case let .filled(dinnerStops) = day.dinner else {
      Issue.record("Expected lunch and dinner stops")
      return
    }
    #expect(lunchStops.map(\.title) == ["Lunch"])
    #expect(dinnerStops.map(\.title) == ["Dinner"])
    #expect(day.alsoThatDay.map(\.title) == ["Gelateria"])
    #expect(lens.badges[lunch.id] == .meal(day: 1, .lunch, ringActive: nil))
    #expect(lens.badges[anytime.id] == .onTrip)
    #expect(lens.badges[museum.id] == .onTrip)
    #expect(lens.badges[breakfast.id] == .onTrip)
  }

  @Test func hotelsGroupStayNightsAndOpenNightsWithoutCheckoutNight() {
    let trip = Trip(id: UUID(), name: "Italy", lengthInDays: 5)
    let hotel = Idea(id: UUID(), name: "Alpine Inn", kind: .stay)
    let stay = TripStay(id: UUID(), tripID: trip.id, ideaID: hotel.id, checkInDay: 1, checkOutDay: 4)
    let regions = (2...5).map { TripDayRegion(id: UUID(), tripID: trip.id, dayNumber: $0, regionID: region.id) }
    let plan = TripPlan(entries: [], ideasByID: [hotel.id: hotel], lengthInDays: 5, tripStays: [stay], dayRegions: regions)
    let lens = GuideTripLens(trip: trip, candidates: [], region: region, category: .hotels, plan: plan, calendar: .current)
    #expect(lens.body == .nights([
      .stay(stayID: stay.id, ideaID: hotel.id, title: "Alpine Inn", isBooked: false, nights: 2...3),
      .open(nights: 4...4),
    ]))
    #expect(lens.badges[hotel.id] == .nights(2...3))
  }
}
