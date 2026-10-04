import Foundation
import SQLiteData

/// A read-only narrative or research document attached to a trip (ADR-0048).
/// Its single real foreign key rides and cascade-deletes with the trip.
@Table
public struct TripDocument: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var title: String
  public var body: String
  public var origin: TripDocumentOrigin
  public var createdAt: Date

  public init(
    id: UUID,
    tripID: Trip.ID,
    title: String,
    body: String,
    origin: TripDocumentOrigin,
    createdAt: Date
  ) {
    self.id = id
    self.tripID = tripID
    self.title = title
    self.body = body
    self.origin = origin
    self.createdAt = createdAt
  }
}

public enum TripDocumentOrigin: Int, QueryBindable, CaseIterable, Sendable {
  case seed = 0
  case pasted = 1
}
