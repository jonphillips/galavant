import Foundation
import SQLiteData

/// A Calendar-authored obligation that has no itinerary-place match.
///
/// The type itself is the provenance: every row exists only because Calendar
/// introduced it, so it can be removed automatically when that event is
/// authoritatively observed deleted. It has one real foreign key (`tripID`) and
/// therefore rides the trip's CloudKit share. Raw EventKit identity remains in
/// device-local reconciliation state; only its one-way hash is shared here.
@Table
public struct CalendarTripConstraint: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var sourceIdentityHash: String
  public var title: String
  public var dayNumber: DayNumber
  public var startTime: String?
  public var endTime: String?
  public var commitmentSnapshot: String

  public init?(
    id: UUID,
    tripID: Trip.ID,
    sourceIdentityHash: String,
    title: String,
    dayNumber: DayNumber,
    startTime: String?,
    endTime: String?,
    commitment: CalendarCommitment
  ) {
    guard let commitmentSnapshot = Self.encode(commitment) else { return nil }
    self.id = id
    self.tripID = tripID
    self.sourceIdentityHash = sourceIdentityHash
    self.title = title
    self.dayNumber = dayNumber
    self.startTime = startTime
    self.endTime = endTime
    self.commitmentSnapshot = commitmentSnapshot
  }

  public init?(
    tripID: Trip.ID,
    event: CalendarObservedEvent,
    projection: CalendarTripDayProjection
  ) {
    guard case let .day(dayNumber, itineraryTimeZone) = projection,
      let commitment = CalendarCommitment(event: event),
      let sourceIdentityHash = CalendarReconciliationFingerprint.constraintSource(for: event)
    else { return nil }
    let times = Self.itineraryTimes(
      for: commitment.temporal,
      absoluteTimeZone: itineraryTimeZone)
    self.init(
      id: CalendarReconciliationFingerprint.constraintID(
        tripID: tripID,
        sourceIdentityHash: sourceIdentityHash),
      tripID: tripID,
      sourceIdentityHash: sourceIdentityHash,
      title: event.title,
      dayNumber: dayNumber,
      startTime: times?.start,
      endTime: times?.end,
      commitment: commitment)
  }

  public var commitment: CalendarCommitment? {
    Self.decode(commitmentSnapshot)
  }

  public var schedule: Schedule {
    if let startTime {
      .timed(dayNumber, start: startTime, end: endTime)
    } else {
      .day(dayNumber)
    }
  }

  public static func upsert(_ constraint: Self, in db: Database) throws {
    try Self.upsert { Self.Draft(constraint) }.execute(db)
  }

  public static func remove(id: Self.ID, in db: Database) throws {
    try Self.find(id).delete().execute(db)
  }

  private static func itineraryTimes(
    for temporal: CalendarEventTime,
    absoluteTimeZone: TimeZone?
  ) -> (start: String, end: String?)? {
    switch temporal {
    case let .absolute(start, end, _):
      guard let absoluteTimeZone else { return nil }
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = absoluteTimeZone
      return (clockTime(start, calendar: calendar), clockTime(end, calendar: calendar))
    case let .floating(start, end):
      return (start.clockDescription, end.clockDescription)
    case .allDay:
      return nil
    }
  }

  private static func clockTime(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
  }

  private static func encode(_ commitment: CalendarCommitment) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? String(decoding: encoder.encode(commitment), as: UTF8.self)
  }

  private static func decode(_ value: String) -> CalendarCommitment? {
    try? JSONDecoder().decode(CalendarCommitment.self, from: Data(value.utf8))
  }
}
