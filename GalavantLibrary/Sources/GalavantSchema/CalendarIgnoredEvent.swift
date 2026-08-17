import Foundation
import SQLiteData

/// A human decision that one shared-calendar event is not part of one trip.
/// The event identity is a hash-only source fingerprint; the row rides the trip's
/// CloudKit share through its one real foreign key.
@Table
public struct CalendarIgnoredEvent: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var sourceIdentityHash: String
  public var title: String
  public var ignoredAt: Date

  public init?(
    tripID: Trip.ID,
    event: CalendarObservedEvent,
    ignoredAt: Date
  ) {
    guard let sourceIdentityHash = CalendarReconciliationFingerprint.constraintSource(for: event)
    else { return nil }
    self.id = CalendarReconciliationFingerprint.ignoredEventID(
      tripID: tripID, sourceIdentityHash: sourceIdentityHash)
    self.tripID = tripID
    self.sourceIdentityHash = sourceIdentityHash
    self.title = event.title
    self.ignoredAt = ignoredAt
  }

  public static func upsert(_ ignored: Self, in db: Database) throws {
    try Self.upsert { Self.Draft(ignored) }.execute(db)
  }

  public static func remove(id: Self.ID, in db: Database) throws {
    try Self.find(id).delete().execute(db)
  }
}
