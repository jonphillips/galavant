import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TripBookingTests {
  @Dependency(\.defaultDatabase) var database
  @Test func resolutionUsesEvidenceThenExplicitThenInference() {
    let cases: [(BookingStatus?, Bool, BookingStatus?, BookingStatus?, ResolvedBooking.Source)] = [
      (.toBook, true, .notNeeded, .booked, .evidence),
      (.notNeeded, false, .toBook, .notNeeded, .explicit),
      (nil, false, .toBook, .toBook, .inferred),
      (nil, false, nil, nil, .inferred),
    ]
    for (explicit, evidence, inferred, status, source) in cases {
      #expect(BookingStatus.resolve(
        explicit: explicit, hasEvidence: evidence, inferred: inferred
      ) == ResolvedBooking(status: status, source: source))
    }

    let stop = TripIdea(
      id: UUID(), tripID: UUID(), ideaID: nil,
      bookingStatus: .notNeeded, confirmationNumber: "  CONF-1  ")
    #expect(stop.resolvedBooking(idea: nil).status == .booked)
    #expect(stop.resolvedBooking(idea: nil).source == .evidence)
  }

  @Test func inferenceTableCoversEveryIdeaKindAndKindlessStops() {
    for kind in IdeaKind.allCases {
      let expected: BookingStatus? = switch kind {
      case .tour, .theater: .toBook
      case .food, .activity, .museum, .nightlife: nil
      default: .notNeeded
      }
      #expect(BookingStatus.inferred(for: kind) == expected)
    }
    #expect(BookingStatus.inferred(for: nil) == .notNeeded)
    #expect(TripStay(id: UUID(), tripID: UUID(), ideaID: nil).resolvedBooking.status == .toBook)
  }

  @Test func tripBookingRollupFiltersRowsAndSortsEachSection() {
    let food = Idea(id: UUID(), name: "Lunch", kind: .food, url: "https://food.example")
    let theater = Idea(id: UUID(), name: "Theater", kind: .theater)
    let other = Idea(id: UUID(), name: "Walk", kind: .sight)
    var rows = [
      stop(food, .scheduled, .timed(2, start: "19:00", end: nil)),
      stop(theater, .scheduled, .timed(2, start: "18:00", end: nil), status: .booked),
      stop(other, .scheduled, .day(2), status: .notNeeded),
      stop(food, .scheduled, .timed(3, start: "12:00", end: nil), status: .booked),
      stop(food, .scheduled, .unscheduled, status: .toBook),
      stop(food, .scheduled, .day(2), status: .toBook),
    ]
    rows[4].completedAt = Date(timeIntervalSince1970: 1)
    let ringID = UUID()
    rows[2].alternativeGroupID = ringID
    rows[2].isActive = true
    rows[5].alternativeGroupID = ringID
    rows[5].isActive = false
    let stays = [
      TripStay(id: UUID(), tripID: UUID(), ideaID: nil, inlineTitle: "Hotel", checkInDay: 2,
        checkOutDay: 4, plannedCheckInTime: "16:00", bookingURL: "https://stay.example"),
      TripStay(id: UUID(), tripID: UUID(), ideaID: nil, inlineTitle: "Past stay", checkInDay: 1,
        checkOutDay: 2),
    ]
    let plan = TripPlan(
      entries: rows,
      ideasByID: [food.id: food, theater.id: theater, other.id: other],
      lengthInDays: 4,
      tripStays: stays)
    let result = TripBookingRollup(plan: plan, currentDay: 2)

    #expect(result.toBookCount == 1)
    #expect(result.toBook.map(\.title) == ["Hotel"])
    #expect(result.toBook[0].bookingURL == "https://stay.example")
    #expect(result.decide.map(\.title) == ["Lunch"])
    #expect(result.decide[0].bookingURL == "https://food.example")
    #expect(result.booked.map(\.title) == ["Theater", "Lunch"])
    #expect(result.booked.map(\.sortTime) == [18 * 60, 12 * 60])
  }

  @Test func bookingColumnsRoundTripAndPinDetailsAreIndependent() async throws {
    let values = try await database.write { db -> (TripIdea, TripStay) in
      let trip = try Trip.create(name: "Booking", certainty: .dated(start: Date()), in: db)
      let idea = try TripIdea.createFreeform(tripID: trip.id, title: "Dinner", in: db)
      let stay = try TripStay.createFreeform(
        tripID: trip.id, title: "Hotel", checkInDay: 1, checkOutDay: 3, in: db)
      try TripIdea.setBookingStatus(.notNeeded, stopID: idea, in: db)
      try TripIdea.setBookingDetails(
        confirmationNumber: "CONF-2", bookingURL: "https://stop.example", partySize: 2,
        stopID: idea, in: db)
      try TripIdea.setPinnedReservation(
        ReservationPin(date: Date(timeIntervalSince1970: 1_800_000_000)), stopID: idea, in: db)
      try TripIdea.setPinnedReservation(nil, stopID: idea, in: db)
      try TripStay.setBookingStatus(.booked, stayID: stay, in: db)
      try TripStay.setBookingDetails(
        confirmationNumber: "HOTEL-8", bookingURL: "https://hotel.example", stayID: stay, in: db)
      return (
        try #require(TripIdea.find(idea).fetchOne(db)),
        try #require(TripStay.find(stay).fetchOne(db)))
    }
    #expect(values.0.pinnedDate == nil)
    #expect(values.0.confirmationNumber == "CONF-2")
    #expect(values.0.bookingURL == "https://stop.example")
    #expect(values.0.partySize == 2)
    #expect(values.0.bookingStatus == .notNeeded)
    #expect(values.1.bookingStatus == .booked)
    #expect(values.1.confirmationNumber == "HOTEL-8")
    #expect(values.1.bookingURL == "https://hotel.example")
  }

  private func stop(
    _ idea: Idea,
    _ lifecycle: TripIdeaStatus,
    _ schedule: Schedule,
    status: BookingStatus? = nil
  ) -> TripIdea {
    var row = TripIdea(
      id: UUID(), tripID: UUID(), ideaID: idea.id,
      status: lifecycle, bookingStatus: status)
    row.apply(schedule)
    return row
  }
}
