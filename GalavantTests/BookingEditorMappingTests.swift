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
      booking: BookingFieldsDraft(inferredStatus: .toBook))

    try await model(for: tripID).saveStop(draft)

    #expect(try await stop(stopID).bookingStatus == nil)
  }

  @Test
  @MainActor
  func changedPickerPersistsTheExplicitChoice() async throws {
    let tripID = try await makeTrip()
    let stopID = try await makeStop(in: tripID)
    var booking = BookingFieldsDraft(inferredStatus: .toBook)
    booking.selectStatus(.notNeeded)
    let draft = StopEditorDraft(
      stopID: stopID,
      stopTitle: "Dinner",
      idea: nil,
      note: "",
      booking: booking)

    try await model(for: tripID).saveStop(draft)

    #expect(try await stop(stopID).bookingStatus == .notNeeded)
  }

  @Test
  @MainActor
  func bookedDetailsSaveWithoutPinningTheDate() async throws {
    let tripID = try await makeTrip()
    let stopID = try await makeStop(in: tripID)
    var booking = BookingFieldsDraft(inferredStatus: .notNeeded)
    booking.selectStatus(.booked)
    booking.confirmationNumber = "ABC-123"
    booking.bookingURL = "https://example.com/booking"
    booking.partySize = "2"
    let draft = StopEditorDraft(
      stopID: stopID,
      stopTitle: "Dinner",
      idea: nil,
      note: "",
      booking: booking)

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
      inferredStatus: .notNeeded,
      isPinned: false,
      confirmationNumber: "ABC-123",
      bookingURL: "https://example.com/booking",
      partySize: "2")
    let draft = StopEditorDraft(
      stopID: stopID,
      stopTitle: "Dinner",
      idea: nil,
      note: "",
      booking: booking)

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
    var booking = BookingFieldsDraft(inferredStatus: .toBook)
    booking.selectStatus(.booked)
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

struct BookingFieldsDraftTests {
  @Test
  func resolutionTracksCurrentPinAndDetails() {
    var draft = BookingFieldsDraft(inferredStatus: .toBook, isPinned: true)
    #expect(draft.resolvedBooking == ResolvedBooking(status: .booked, source: .evidence))

    draft.isPinned = false
    #expect(draft.resolvedBooking == ResolvedBooking(status: .toBook, source: .inferred))

    draft.selectStatus(.booked)
    draft.confirmationNumber = "CONF-1"
    #expect(draft.resolvedBooking == ResolvedBooking(status: .booked, source: .evidence))
    draft.confirmationNumber = ""
    draft.selectStatus(.toBook)
    #expect(draft.resolvedBooking == ResolvedBooking(status: .toBook, source: .explicit))
  }

  @Test
  func changingFromBookedToToBookClearsConfirmationButKeepsBookLink() {
    var draft = BookingFieldsDraft(inferredStatus: .notNeeded)
    draft.selectStatus(.booked)
    draft.confirmationNumber = "CONF-1"
    draft.partySize = "2"
    draft.bookingURL = "https://example.com/book"
    #expect(draft.resolvedBooking == ResolvedBooking(status: .booked, source: .evidence))

    // Confirmation evidence must be cleared before the explicit To book choice
    // can take effect; a URL is useful in that state and remains available.
    draft.confirmationNumber = ""
    draft.selectStatus(.toBook)

    #expect(draft.resolvedBooking == ResolvedBooking(status: .toBook, source: .explicit))
    #expect(draft.bookingDetails.confirmationNumber == nil)
    #expect(draft.bookingDetails.partySize == nil)
    #expect(draft.bookingDetails.bookingURL == "https://example.com/book")
  }
}
