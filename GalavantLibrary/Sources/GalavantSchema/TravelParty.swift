import Foundation
import SQLiteData

/// The group that plans and travels together — the shared root every other
/// record hangs off (ADR-0003). Members are `Planner`s. Identity is the iCloud
/// account graph; there is no auth.
@Table
public struct TravelParty: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name = "Our Travels"

  public init(id: UUID, name: String = "Our Travels") {
    self.id = id
    self.name = name
  }
}

extension TravelParty {
  /// The default travel party: the one shared party everything belongs to.
  /// Derived from data (not a device setting) so it resolves to the same party
  /// on every member's device. Created once on first use.
  public static func ensureDefault(in db: Database) throws -> TravelParty {
    if let existing = try TravelParty.order(by: \.id).fetchOne(db) {
      return existing
    }
    try TravelParty.insert { TravelParty.Draft(name: "Our Travels") }.execute(db)
    guard let created = try TravelParty.order(by: \.id).fetchOne(db) else {
      throw TravelPartyError.creationFailed
    }
    return created
  }
}

public enum TravelPartyError: Error {
  case creationFailed
}
