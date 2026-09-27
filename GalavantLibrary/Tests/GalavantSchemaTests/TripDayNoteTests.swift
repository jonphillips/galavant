import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

/// A trip day's one-line purpose note: at most one row per day, blank clears, and a
/// derived id so two devices writing the same day converge on one record.
@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TripDayNoteTests {
  @Dependency(\.defaultDatabase) var database

  @Test("Setting a note twice replaces it — one row per day")
  func setReplaces() async throws {
    let rows = try await database.write { db -> [TripDayNote] in
      let trip = try Trip.create(name: "Burgundy", lengthInDays: 5, in: db)
      try TripDayNote.set("Wine tasting", forTrip: trip.id, day: 2, in: db)
      try TripDayNote.set("Beaune market", forTrip: trip.id, day: 2, in: db)
      return try TripDayNote.where { $0.tripID.eq(trip.id) }.fetchAll(db)
    }
    #expect(rows.map(\.note) == ["Beaune market"])
    #expect(rows.first?.dayNumber == 2)
  }

  @Test("A blank note clears the day")
  func blankClears() async throws {
    let count = try await database.write { db -> Int in
      let trip = try Trip.create(name: "Burgundy", lengthInDays: 5, in: db)
      try TripDayNote.set("Travel day", forTrip: trip.id, day: 1, in: db)
      try TripDayNote.set("  \n ", forTrip: trip.id, day: 1, in: db)
      return try TripDayNote.where { $0.tripID.eq(trip.id) }.fetchCount(db)
    }
    #expect(count == 0)
  }

  @Test("The note is trimmed and folded to one line")
  func foldsToOneLine() async throws {
    let note = try await database.write { db -> String? in
      let trip = try Trip.create(name: "Burgundy", lengthInDays: 5, in: db)
      try TripDayNote.set("  Hike\nthen picnic  ", forTrip: trip.id, day: 3, in: db)
      return try TripDayNote.where { $0.tripID.eq(trip.id) }.fetchOne(db)?.note
    }
    #expect(note == "Hike then picnic")
  }

  @Test("Notes are scoped to their own trip and day")
  func scopedToTripAndDay() async throws {
    let (france, italy) = try await database.write { db -> ([TripDayNote], [TripDayNote]) in
      let france = try Trip.create(name: "France", lengthInDays: 4, in: db)
      let italy = try Trip.create(name: "Italy", lengthInDays: 4, in: db)
      try TripDayNote.set("Paris", forTrip: france.id, day: 1, in: db)
      try TripDayNote.set("Loire", forTrip: france.id, day: 2, in: db)
      try TripDayNote.set("Rome", forTrip: italy.id, day: 1, in: db)
      try TripDayNote.set("", forTrip: france.id, day: 1, in: db)
      return (
        try TripDayNote.where { $0.tripID.eq(france.id) }.fetchAll(db),
        try TripDayNote.where { $0.tripID.eq(italy.id) }.fetchAll(db)
      )
    }
    #expect(france.map(\.note) == ["Loire"])
    #expect(italy.map(\.note) == ["Rome"])
  }

  @Test("The id is derived from trip and day, so devices converge")
  func deterministicID() {
    let tripID = UUID()
    #expect(TripDayNote.id(tripID: tripID, day: 3) == TripDayNote.id(tripID: tripID, day: 3))
    #expect(TripDayNote.id(tripID: tripID, day: 3) != TripDayNote.id(tripID: tripID, day: 4))
    #expect(TripDayNote.id(tripID: tripID, day: 3) != TripDayNote.id(tripID: UUID(), day: 3))
    #expect(
      TripDayNote(tripID: tripID, dayNumber: 3, note: "x").id
        == TripDayNote.id(tripID: tripID, day: 3))
  }
}
