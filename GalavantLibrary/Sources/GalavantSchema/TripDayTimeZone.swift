import Foundation
import SQLiteData

/// A shared, per-day assignment-zone override. Presence of a row means the day
/// has an explicit zone; absence resolves through its region and trip centroid.
@Table
public struct TripDayTimeZone: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var dayNumber: DayNumber
  public var timeZoneIdentifier: String?

  public init(
    id: UUID? = nil, tripID: Trip.ID, dayNumber: DayNumber, timeZoneIdentifier: String
  ) {
    self.id = id ?? CalendarReconciliationFingerprint.timeZoneID(
      tripID: tripID, day: dayNumber)
    self.tripID = tripID
    self.dayNumber = dayNumber
    self.timeZoneIdentifier = timeZoneIdentifier
  }

  public static func timeZone(
    forTrip tripID: Trip.ID, day: DayNumber, in db: Database
  ) throws -> TimeZone? {
    try Self
      .where { $0.tripID.eq(tripID) && $0.dayNumber.eq(day) }
      .fetchAll(db)
      .first
      .flatMap { $0.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) }
  }

  public static func set(
    _ timeZoneIdentifier: String?, forTrip tripID: Trip.ID, day: DayNumber, in db: Database
  ) throws {
    try Self.where { $0.tripID.eq(tripID) && $0.dayNumber.eq(day) }.delete().execute(db)
    guard let timeZoneIdentifier else { return }
    try Self.upsert {
      Self.Draft(Self(
        tripID: tripID, dayNumber: day, timeZoneIdentifier: timeZoneIdentifier))
    }.execute(db)
  }
}
