import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantPlaces
import GalavantSchema
import SQLiteData
import Testing

@testable import Galavant

private let bookingTokyo = TimeZone(identifier: "Asia/Tokyo")!
private let bookingOpening = Date(timeIntervalSince1970: 1_802_000_000)

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

  @Test
  @MainActor
  func untouchedOpeningDoesNotOverwriteAPeersDate() async throws {
    let tripID = try await makeTrip()
    let stopID = try await makeStop(in: tripID)
    let draft = StopEditorDraft(
      stopID: stopID,
      stopTitle: "Dinner",
      idea: nil,
      note: "Window seat",
      booking: BookingFieldsDraft(inferredStatus: .toBook, tracksOpening: true))
    try await database.write { db in
      try TripIdea.setBookingOpensAt(bookingOpening, stopID: stopID, in: db)
    }

    try await model(for: tripID).saveStop(draft)

    #expect(try await stop(stopID).bookingOpensAt == bookingOpening)
  }

  @Test
  @MainActor
  func changedOpeningIsSaved() async throws {
    let tripID = try await makeTrip()
    let stopID = try await makeStop(in: tripID)
    var booking = BookingFieldsDraft(
      inferredStatus: .toBook, tracksOpening: true, openingDate: bookingOpening)
    booking.openingDate = bookingOpening.addingTimeInterval(3600)
    let draft = StopEditorDraft(
      stopID: stopID, stopTitle: "Dinner", idea: nil, note: "", booking: booking)

    try await model(for: tripID).saveStop(draft)

    #expect(try await stop(stopID).bookingOpensAt == bookingOpening.addingTimeInterval(3600))
  }

  @Test(.dependencies { $0.date = .constant(bookingOpening) })
  @MainActor
  func openingEditorAndSheetUseResolvedDayZone() async throws {
    let tripID = try await makeTrip()
    let tokyoID = UUID()
    let losAngelesID = UUID()
    let tokyoRegion = MapRegion(
      id: tokyoID, name: "Tokyo", centerLatitude: 35.68, centerLongitude: 139.69,
      latitudeDelta: 1, longitudeDelta: 1)
    let losAngelesRegion = MapRegion(
      id: losAngelesID, name: "Los Angeles", centerLatitude: 34.05, centerLongitude: -118.24,
      latitudeDelta: 1, longitudeDelta: 1)
    let idea = Idea(id: UUID(), name: "Dinner", kind: .food)
    let entry = TripIdea(
      id: UUID(), tripID: tripID, ideaID: idea.id, status: .scheduled, dayNumber: 1)
    try await database.write { db in
      try MapRegion.insert { [MapRegion.Draft(tokyoRegion), MapRegion.Draft(losAngelesRegion)] }
        .execute(db)
      try Idea.insert { Idea.Draft(idea) }.execute(db)
      try TripIdea.insert { TripIdea.Draft(entry) }.execute(db)
      try TripRegion.setRegions([losAngelesID], forTrip: tripID, in: db)
      try TripDayRegion.setRegion(tokyoID, forTrip: tripID, day: 1, in: db)
      try TripDayRegion.setRegion(tokyoID, forTrip: tripID, day: 2, in: db)
      try TripDayTimeZone.set("America/New_York", forTrip: tripID, day: 2, in: db)
    }
    let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    let matcher = PlaceMatcher(
      geocode: { _ in nil },
      search: { _ in [] },
      timeZone: { _, longitude in longitude > 0 ? bookingTokyo : losAngeles })
    let model = withDependencies {
      $0.placeMatcher = matcher
    } operation: {
      TripPlanningModel(tripID: tripID)
    }
    try await model.$trips.load()
    try await model.$regions.load()
    try await model.$ideas.load()
    try await model.$allTripRegions.load()
    try await model.$allTripDayRegions.load()
    try await model.$allTripDayTimeZones.load()
    try await model.$allTripIdeas.load()
    await model.refreshDayTimeZones()

    let draft = model.bookingFields(for: ResolvedStop(entry: entry, content: .idea(idea)))
    #expect(draft.openingTimeZone == bookingTokyo)
    #expect(model.dayTimeZone(forDay: 1) == bookingTokyo)
    #expect(model.dayTimeZone(forDay: 2) == TimeZone(identifier: "America/New_York"))
    #expect(model.dayTimeZone(forDay: 3) == losAngeles)
    // The day header and zone menu show only a hand-set zone.
    #expect(model.dayTimeZoneOverride(forDay: 1) == nil)
    #expect(model.dayTimeZoneOverride(forDay: 2) == TimeZone(identifier: "America/New_York"))
    #expect(model.dayTimeZoneOverride(forDay: 3) == nil)
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

  // MARK: - Booking opens (ADR-0056 D1)

  @Test
  func openingToggleOffSavesNoDate() {
    var draft = BookingFieldsDraft(
      inferredStatus: .toBook, tracksOpening: true, openingDate: bookingOpening)
    draft.hasOpeningDate = false

    #expect(draft.bookingOpeningDate == nil)
    #expect(draft.openingWasChanged)
  }

  @Test
  func alreadyOpenRecordsNow() {
    let now = Date(timeIntervalSince1970: 1_801_000_000)
    var draft = BookingFieldsDraft(inferredStatus: .toBook, tracksOpening: true)
    draft.alreadyOpenButtonTapped(now: now)

    #expect(draft.bookingOpeningDate == now)
  }

  @Test
  func choosingBookedKeepsTheOpeningDate() {
    var draft = BookingFieldsDraft(
      inferredStatus: .toBook, tracksOpening: true, openingDate: bookingOpening)
    draft.selectStatus(.booked)
    draft.selectStatus(.toBook)

    #expect(draft.bookingOpeningDate == bookingOpening)
    #expect(!draft.openingWasChanged)
  }

  @Test
  func untrackedStopHasNoOpening() {
    let draft = BookingFieldsDraft(
      inferredStatus: .toBook, tracksOpening: false, openingDate: bookingOpening)

    #expect(draft.bookingOpeningDate == nil)
  }

  @Test
  func blankOpeningSeedsTomorrowAtTenInTheOpeningZone() throws {
    let now = Date(timeIntervalSince1970: 1_801_000_000)
    var draft = BookingFieldsDraft(
      inferredStatus: .toBook, now: now, tracksOpening: true, openingTimeZone: bookingTokyo)
    draft.hasOpeningDate = true

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = bookingTokyo
    let seeded = try #require(draft.bookingOpeningDate)
    #expect(seeded > now)
    #expect(calendar.component(.hour, from: seeded) == 10)
    #expect(calendar.component(.minute, from: seeded) == 0)
    #expect(calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: seeded).day == 1)
  }

  @Test
  func openingFormatFollowsTheLocaleClock() {
    let utc = TimeZone(identifier: "UTC")!
    let british = BookingOpeningFormat.string(
      moment: bookingOpening, timeZone: bookingTokyo, deviceTimeZone: utc,
      locale: Locale(identifier: "en_GB"))
    let american = BookingOpeningFormat.string(
      moment: bookingOpening, timeZone: bookingTokyo, deviceTimeZone: utc,
      locale: Locale(identifier: "en_US"))

    #expect(british.contains("20:33"))
    #expect(!british.contains("PM"))
    #expect(american.contains("8:33"))
    #expect(american.contains("PM"))
  }

  @Test
  func openingZoneLabelOnlyWhenAwayFromTheDevicesZone() {
    let newYork = TimeZone(identifier: "America/New_York")!
    let july = Date(timeIntervalSince1970: 1_815_000_000)

    #expect(BookingOpeningFormat.zoneLabel(
      moment: bookingOpening, timeZone: bookingTokyo, deviceTimeZone: bookingTokyo) == nil)
    #expect(BookingOpeningFormat.zoneLabel(
      moment: july, timeZone: newYork, deviceTimeZone: bookingTokyo) == "EDT")
    #expect(BookingOpeningFormat.zoneLabel(
      moment: bookingOpening, timeZone: newYork, deviceTimeZone: bookingTokyo) == "EST")
  }
}
