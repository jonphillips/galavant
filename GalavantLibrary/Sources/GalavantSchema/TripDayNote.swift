import Foundation
import SQLiteData

/// A one-line note on a trip day saying what the day is *for* — "Wine tasting in
/// Beaune", "Travel day", "Recover". Shown under the day's header on the itinerary;
/// written from the day's "+" sheet.
///
/// Mirrors `TripDayTimeZone`: a single real foreign key to `Trip` (rides the trip's
/// share, cascade-deletes with it), and at most one row per `(tripID, dayNumber)`.
/// The id is *derived* from `(tripID, dayNumber)`, so two devices writing the same
/// day's note converge on one CloudKit record instead of racing two rows in. A blank
/// note is no row. A day past a since-shortened trip keeps its row as a tolerated
/// orphan, the same as a `TripDayRegion` — it simply never displays.
@Table
public struct TripDayNote: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var dayNumber: DayNumber
  public var note: String

  public init(tripID: Trip.ID, dayNumber: DayNumber, note: String) {
    self.id = Self.id(tripID: tripID, day: dayNumber)
    self.tripID = tripID
    self.dayNumber = dayNumber
    self.note = note
  }

  /// The deterministic record id for a trip day's note.
  public static func id(tripID: Trip.ID, day: DayNumber) -> UUID {
    CalendarReconciliationFingerprint.dayNoteID(tripID: tripID, day: day)
  }

  /// Set (or, with a blank note, clear) a day's note. Whitespace is trimmed and
  /// newlines fold to spaces — it's a one-line caption.
  public static func set(
    _ note: String, forTrip tripID: Trip.ID, day: DayNumber, in db: Database
  ) throws {
    let line = note
      .components(separatedBy: .newlines)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    try Self.where { $0.tripID.eq(tripID) && $0.dayNumber.eq(day) }.delete().execute(db)
    guard !line.isEmpty else { return }
    try Self.upsert {
      Self.Draft(Self(tripID: tripID, dayNumber: day, note: line))
    }.execute(db)
  }
}
