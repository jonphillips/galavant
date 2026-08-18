import Foundation
import SQLiteData

/// The optional shared label for an ADR-0035 alternatives ring. The primary key
/// is the ring's `alternativeGroupID`; `tripID` is the one real foreign key so
/// the row rides the trip's CloudKit share.
@Table
public struct TripAlternativeGroup: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var label: String

  public init(id: UUID, tripID: Trip.ID, label: String) {
    self.id = id
    self.tripID = tripID
    self.label = label
  }

  /// Create or rename a ring label. An empty label removes the optional row so
  /// the read model naturally renders no header.
  public static func rename(
    groupID: UUID,
    tripID: Trip.ID,
    label: String,
    in db: Database
  ) throws {
    let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedLabel.isEmpty {
      try Self.find(groupID).delete().execute(db)
      return
    }
    try Self.upsert {
      Self.Draft(Self(id: groupID, tripID: tripID, label: normalizedLabel))
    }.execute(db)
  }

  /// Read the label for a ring, treating an empty stored value as absent.
  public static func readLabel(for groupID: UUID, in db: Database) throws -> String? {
    guard let group = try Self.find(groupID).fetchOne(db) else { return nil }
    let label = group.label.trimmingCharacters(in: .whitespacesAndNewlines)
    return label.isEmpty ? nil : label
  }
}
