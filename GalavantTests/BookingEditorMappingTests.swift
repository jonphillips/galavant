import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import Galavant

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct BookingEditorMappingTests {
  @Dependency(\.defaultDatabase) private var database

  private func makeTrip() async throws -> Trip.ID {
    let id = UUID()
    try await database.write { db in
      try Trip.insert {
        Trip.Draft(Trip(id: id, name: "Booking test", certaintyStage: .someday, lengthInDays: 3))
      }
      .execute(db)
    }
    return id
  }

  private func makeStop(in tripID: Trip.ID) async throws -> TripIdea.ID {
    try await database.write { db in
      try TripIdea.createFreeform(tripID: tripID, title: "Dinner", in: db)
    }
  }

  @MainActor
  private func model(for tripID: Trip.ID) async throws -> TripPlanningModel {
    let model = TripPlanningModel(tripID: tripID)
    try await model.$trips.load()
    return model
  }

  private func stop(_ id: TripIdea.ID) async throws -> TripIdea {
    try await database.read { db in try TripIdea.find(id).fetchOne(db)! }
  }

  @Test
  @MainActor
  func unchangedPickerDoesNotWriteAnExplicitStatus() async throws {
    let tripID = try await makeTrip()
    let stopID = try await makeStop(in: tripID)
    let draft = StopEditorDraft(
      stopID: stopID,
      stopTitle: "Dinner",
      idea: nil,
      note: "",
      booking: BookingFieldsDraft(resolvedStatus: .toBook),
      calendarLinked: false)

    try await model(for: tripID).saveStop(draft)

    #expect(try await stop(stopID).bookingStatus == nil)
  }

  @Test
  @MainActor
  func changedPickerPersistsTheExplicitChoice() async throws {
    let tripID = try await makeTrip()
    let stopID = try await makeStop(in: tripID)
    var booking = BookingFieldsDraft(resolvedStatus: .toBook)
    booking.explicitStatus = .notNeeded
    booking.statusWasChanged = true
    let draft = StopEditorDraft(
      stopID: stopID,
      stopTitle: "Dinner",
      idea: nil,
      note: "",
      booking: booking,
      calendarLinked: false)

    try await model(for: tripID).saveStop(draft)

    #expect(try await stop(stopID).bookingStatus == .notNeeded)
  }

  @Test
  @MainActor
  func bookedDetailsSaveWithoutPinningTheDate() async throws {
    let tripID = try await makeTrip()
    let stopID = try await makeStop(in: tripID)
    var booking = BookingFieldsDraft(resolvedStatus: .notNeeded)
    booking.explicitStatus = .booked
    booking.statusWasChanged = true
    booking.confirmationNumber = "ABC-123"
    booking.bookingURL = "https://example.com/booking"
    booking.partySize = "2"
    let draft = StopEditorDraft(
      stopID: stopID,
      stopTitle: "Dinner",
      idea: nil,
      note: "",
      booking: booking,
      calendarLinked: false)

    try await model(for: tripID).saveStop(draft)

    let saved = try await stop(stopID)
    #expect(saved.bookingStatus == .booked)
    #expect(saved.pinnedDate == nil)
    #expect(saved.confirmationNumber == "ABC-123")
    #expect(saved.bookingURL == "https://example.com/booking")
    #expect(saved.partySize == 2)
  }

  @Test
  @MainActor
  func unpinningKeepsTheBookingDetails() async throws {
    let tripID = try await makeTrip()
    let stopID = try await makeStop(in: tripID)
    try await database.write { db in
      try TripIdea.setBookingDetails(
        confirmationNumber: "ABC-123",
        bookingURL: "https://example.com/booking",
        partySize: 2,
        stopID: stopID,
        in: db)
      try TripIdea.setPinnedReservation(
        ReservationPin(date: .now), stopID: stopID, in: db)
    }
    let booking = BookingFieldsDraft(
      resolvedStatus: .booked,
      source: .evidence,
      isPinned: false,
      confirmationNumber: "ABC-123",
      bookingURL: "https://example.com/booking",
      partySize: "2")
    let draft = StopEditorDraft(
      stopID: stopID,
      stopTitle: "Dinner",
      idea: nil,
      note: "",
      booking: booking,
      calendarLinked: false)

    try await model(for: tripID).saveStop(draft)

    let saved = try await stop(stopID)
    #expect(saved.pinnedDate == nil)
    #expect(saved.confirmationNumber == "ABC-123")
    #expect(saved.bookingURL == "https://example.com/booking")
    #expect(saved.partySize == 2)
  }

  @Test
  @MainActor
  func stayEditorPersistsBookingChoiceAndDetails() async throws {
    let tripID = try await makeTrip()
    let stayID = try await database.write { db in
      try TripStay.createFreeform(
        tripID: tripID,
        title: "Hotel",
        checkInDay: 1,
        checkOutDay: 2,
        in: db)
    }
    var booking = BookingFieldsDraft(resolvedStatus: .toBook)
    booking.explicitStatus = .booked
    booking.statusWasChanged = true
    booking.confirmationNumber = "STAY-456"
    booking.bookingURL = "https://example.com/stay"
    let draft = StayDraft(
      stayID: stayID,
      title: "Hotel",
      checkInDay: 1,
      checkOutDay: 2,
      booking: booking)

    try await model(for: tripID).saveStay(draft)

    let saved = try await database.read { db in try TripStay.find(stayID).fetchOne(db)! }
    #expect(saved.bookingStatus == .booked)
    #expect(saved.confirmationNumber == "STAY-456")
    #expect(saved.bookingURL == "https://example.com/stay")
  }
}
