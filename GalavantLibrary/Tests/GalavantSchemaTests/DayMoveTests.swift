import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite struct DayMoveTests {
  @Test("A move maps every intervening day and leaves a self-move empty")
  func mapping() {
    #expect(DayMove(from: 2, to: 5).mapping() == [2: 5, 3: 2, 4: 3, 5: 4])
    #expect(DayMove(from: 5, to: 2).mapping() == [5: 2, 4: 5, 3: 4, 2: 3])
    #expect(DayMove(from: 1, to: 2).mapping() == [1: 2, 2: 1])
    #expect(DayMove(from: 1, to: 5).mapping() == [1: 5, 2: 1, 3: 2, 4: 3, 5: 4])
    #expect(DayMove(from: 3, to: 3).mapping().isEmpty)
    #expect(DayMove(from: 3, to: 3).affectedDays == 3...3)
  }

  @Test("Validation refuses a lock in the affected range, but ignores outside locks and self-moves")
  func validation() {
    let move = DayMove(from: 2, to: 4)
    #expect(move.validate(locks: [3: .past], dayLabel: { "Day \($0)" }) == .locked(
      day: 3, label: "Day 3", .past))
    #expect(move.validate(locks: [1: .past, 5: .past], dayLabel: { "Day \($0)" }) == nil)
    #expect(DayMove(from: 3, to: 3).validate(
      locks: [3: .booking(title: "Erst")], dayLabel: { "Day \($0)" }) == nil)
    #expect(DayMoveRefusal.locked(day: 2, label: "Thu 15 Jul", .booking(title: "Erst"))
      .localizedDescription == "Thu 15 Jul has a booking: Erst")
  }
}

@Suite struct TripDayDesignLockTests {
  @Test("Pinned and booked stops lock their day; skipped bookings stay locked")
  func bookingsLockDays() {
    let trip = Trip(id: UUID(), name: "France", certaintyStage: .dated,
      startDate: date(2027, 7, 14), lengthInDays: 3)
    let pinned = stop(day: 1, title: "Dinner", pinnedDate: date(2027, 7, 14))
    let booked = stop(day: 2, title: "Museum", bookingStatus: .booked)
    var skippedBooking = stop(day: 3, title: "Train", bookingStatus: .booked)
    skippedBooking.entry.skippedAt = date(2027, 7, 1)
    let rows = TripDayDesign.rows(
      trip: trip, dayRegions: [], dayTimeZones: [], dayNotes: [], stays: [],
      stops: [pinned, booked, skippedBooking], now: date(2027, 7, 14))

    #expect(rows.map(\.lock) == [
      .booking(title: "Dinner"), .booking(title: "Museum"), .booking(title: "Train")
    ])
  }

  @Test("Past days lock only when the trip is dated")
  func pastAndUndatedLocks() {
    let start = date(2027, 7, 10)
    let dated = Trip(id: UUID(), name: "France", certaintyStage: .dated,
      startDate: start, lengthInDays: 3)
    let datedRows = TripDayDesign.rows(
      trip: dated, dayRegions: [], dayTimeZones: [], dayNotes: [], stays: [], stops: [],
      now: date(2027, 7, 12))
    #expect(datedRows.map(\.lock) == [.past, .past, nil])

    let undated = Trip(id: UUID(), name: "Someday", lengthInDays: 3)
    let undatedRows = TripDayDesign.rows(
      trip: undated, dayRegions: [], dayTimeZones: [], dayNotes: [], stays: [], stops: [],
      now: date(2027, 7, 12))
    #expect(undatedRows.map(\.lock) == [nil, nil, nil])
  }
}

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TripMoveDayDatabaseTests {
  @Dependency(\.defaultDatabase) var database

  @Test("Moving a day carries stops and design rows, regenerates derived ids, and leaves stays alone")
  func moveCarriesDayData() async throws {
    let result = try await database.write { db -> (
      Trip.ID, [TripIdea], [TripDayNote], [TripDayTimeZone], [TripDayRegion], TripStay, [Int: UUID]
    ) in
      let trip = try Trip.create(name: "France", lengthInDays: 4, in: db)
      var stops: [TripIdea] = []
      var assignments: [TripDayRegion] = []
      for day in 1...4 {
        var stop = TripIdea.freeform(
          id: UUID(), tripID: trip.id, title: "Stop \(day)", shortlistRank: day)
        stop.apply(.timed(day, start: "09:00", end: "10:00"))
        stop.dayRank = Double(day) + 0.5
        try TripIdea.insert { TripIdea.Draft(stop) }.execute(db)
        stops.append(stop)
        try TripDayNote.set("Summary \(day)", forTrip: trip.id, day: day, in: db)
        try TripDayTimeZone.set("Europe/Paris", forTrip: trip.id, day: day, in: db)
        assignments.append(TripDayRegion(
          id: UUID(), tripID: trip.id, dayNumber: day, regionID: UUID()))
      }
      try TripDayRegion.insert { assignments.map(TripDayRegion.Draft.init) }.execute(db)
      let stay = TripStay.freeform(
        id: UUID(), tripID: trip.id, title: "Hotel", checkInDay: 1, checkOutDay: 3)
      try TripStay.insert { TripStay.Draft(stay) }.execute(db)

      try Trip.moveDay(DayMove(from: 1, to: 3), tripID: trip.id, now: date(2027, 1, 1), in: db)
      return (
        trip.id,
        try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db),
        try TripDayNote.where { $0.tripID.eq(trip.id) }.fetchAll(db),
        try TripDayTimeZone.where { $0.tripID.eq(trip.id) }.fetchAll(db),
        try TripDayRegion.where { $0.tripID.eq(trip.id) }.fetchAll(db),
        try TripStay.find(stay.id).fetchOne(db)!,
        Dictionary(uniqueKeysWithValues: assignments.map { ($0.dayNumber, $0.regionID) })
      )
    }
    let (tripID, stops, notes, zones, regions, stay, originalRegions) = result
    #expect(Dictionary(uniqueKeysWithValues: stops.map { ($0.inlineTitle!, $0.dayNumber!) }) == [
      "Stop 1": 3, "Stop 2": 1, "Stop 3": 2, "Stop 4": 4
    ])
    #expect(Dictionary(uniqueKeysWithValues: stops.map { ($0.inlineTitle!, $0.dayRank) }) == [
      "Stop 1": 1.5, "Stop 2": 2.5, "Stop 3": 3.5, "Stop 4": 4.5
    ])
    #expect(Dictionary(uniqueKeysWithValues: notes.map { ($0.dayNumber, $0.note) }) == [
      1: "Summary 2", 2: "Summary 3", 3: "Summary 1", 4: "Summary 4"
    ])
    #expect(notes.allSatisfy { $0.id == TripDayNote.id(tripID: tripID, day: $0.dayNumber) })
    #expect(Dictionary(uniqueKeysWithValues: zones.map { ($0.dayNumber, $0.timeZoneIdentifier!) }) == [
      1: "Europe/Paris", 2: "Europe/Paris", 3: "Europe/Paris", 4: "Europe/Paris"
    ])
    let zoneIDsMatch = zones.allSatisfy { zone in
      zone.id == TripDayTimeZone(
        tripID: tripID, dayNumber: zone.dayNumber,
        timeZoneIdentifier: zone.timeZoneIdentifier ?? "").id
    }
    #expect(zoneIDsMatch)
    let actualRegions = Dictionary(uniqueKeysWithValues: regions.map { ($0.dayNumber, $0.regionID) })
    let expectedRegions: [Int: UUID] = [
      1: originalRegions[2]!, 2: originalRegions[3]!, 3: originalRegions[1]!, 4: originalRegions[4]!
    ]
    #expect(actualRegions == expectedRegions)
    #expect(stay.checkInDay == 1)
    #expect(stay.checkOutDay == 3)

    let restored = try await database.write { db -> ([TripIdea], [TripDayNote], [TripDayRegion]) in
      try Trip.moveDay(DayMove(from: 3, to: 1), tripID: tripID, now: date(2027, 1, 1), in: db)
      return (
        try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db),
        try TripDayNote.where { $0.tripID.eq(tripID) }.fetchAll(db),
        try TripDayRegion.where { $0.tripID.eq(tripID) }.fetchAll(db))
    }
    let restoredStops = Dictionary(uniqueKeysWithValues: restored.0.map { ($0.inlineTitle!, $0.dayNumber!) })
    #expect(restoredStops == ["Stop 1": 1, "Stop 2": 2, "Stop 3": 3, "Stop 4": 4])
    let restoredNotes = Dictionary(uniqueKeysWithValues: restored.1.map { ($0.dayNumber, $0.note) })
    #expect(restoredNotes == [
      1: "Summary 1", 2: "Summary 2", 3: "Summary 3", 4: "Summary 4"
    ])
    let restoredRegions = Dictionary(uniqueKeysWithValues: restored.2.map { ($0.dayNumber, $0.regionID) })
    #expect(restoredRegions == originalRegions)
  }

  @Test("A lock added before the write refuses the move without changing any rows")
  func lockRefusesWithoutChanges() async throws {
    let result = try await database.write { db -> (Trip.ID, [TripIdea], [TripDayNote]) in
      let trip = try Trip.create(name: "France", lengthInDays: 3, in: db)
      var first = TripIdea.freeform(id: UUID(), tripID: trip.id, title: "One")
      first.apply(.day(1))
      var booked = TripIdea.freeform(id: UUID(), tripID: trip.id, title: "Reservation")
      booked.apply(.day(2))
      booked.bookingStatus = .booked
      try TripIdea.insert { TripIdea.Draft(first) }.execute(db)
      try TripIdea.insert { TripIdea.Draft(booked) }.execute(db)
      try TripDayNote.set("First", forTrip: trip.id, day: 1, in: db)
      try TripDayNote.set("Second", forTrip: trip.id, day: 2, in: db)
      return (trip.id,
        try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db),
        try TripDayNote.where { $0.tripID.eq(trip.id) }.fetchAll(db))
    }
    let originalStops = result.1
    let originalNotes = result.2
    await #expect(throws: DayMoveRefusal.locked(day: 2, label: "Day 2", .booking(title: "Reservation"))) {
      try await database.write { db in
        try Trip.moveDay(DayMove(from: 1, to: 3), tripID: result.0, now: date(2027, 1, 1), in: db)
      }
    }
    let unchanged = try await database.read { db in
      (
        try TripIdea.where { $0.tripID.eq(result.0) }.fetchAll(db),
        try TripDayNote.where { $0.tripID.eq(result.0) }.fetchAll(db)
      )
    }
    #expect(unchanged.0 == originalStops)
    #expect(unchanged.1 == originalNotes)
  }
}

private func stop(
  day: Int, title: String, pinnedDate: Date? = nil, bookingStatus: BookingStatus? = nil
) -> ResolvedStop {
  var entry = TripIdea.freeform(id: UUID(), tripID: UUID(), title: title)
  entry.apply(.day(day))
  entry.pinnedDate = pinnedDate
  entry.bookingStatus = bookingStatus
  return ResolvedStop(entry: entry, content: .freeform(title: title, note: nil, coordinate: nil))
}

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}
