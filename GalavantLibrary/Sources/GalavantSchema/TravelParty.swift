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
  /// on every member's device. A party with members/content wins over an empty
  /// first-run stray; ties resolve to the lowest id. Created once on first use.
  public static func ensureDefault(in db: Database) throws -> TravelParty {
    let parties = try TravelParty.order(by: \.id).fetchAll(db)
    if let lowestParty = parties.first {
      let survivor = try parties.first { try $0.hasContent(in: db) } ?? lowestParty
      let losers = parties.filter { $0.id != survivor.id }
      try repointChildren(of: losers, to: survivor, in: db)
      for loser in losers {
        // Every direct child FK is repointed above. Foreign keys stay enabled so
        // cascade now only cleans any future child type this audit missed loudly.
        try TravelParty.find(loser.id).delete().execute(db)
      }
      return survivor
    }
    try TravelParty.insert {
      TravelParty.Draft(TravelParty(id: UUID(), name: "Our Travels"))
    }
    .execute(db)
    guard let created = try TravelParty.order(by: \.id).fetchOne(db) else {
      throw TravelPartyError.creationFailed
    }
    return created
  }

  private func hasContent(in db: Database) throws -> Bool {
    if try Planner.where({ $0.travelPartyID.eq(id) }).fetchOne(db) != nil { return true }
    if try Idea.where({ $0.travelPartyID.eq(id) }).fetchOne(db) != nil { return true }
    if try MapRegion.where({ $0.travelPartyID.eq(id) }).fetchOne(db) != nil { return true }
    if try Tag.where({ $0.travelPartyID.eq(id) }).fetchOne(db) != nil { return true }
    if try Trip.where({ $0.travelPartyID.eq(id) }).fetchOne(db) != nil { return true }
    if try IdeaEvaluation.where({ $0.travelPartyID.eq(id) }).fetchOne(db) != nil { return true }
    if try TravelProfile.where({ $0.travelPartyID.eq(id) }).fetchOne(db) != nil { return true }
    return false
  }

  private static func repointChildren(
    of losers: [TravelParty],
    to survivor: TravelParty,
    in db: Database
  ) throws {
    for loser in losers {
      try Planner.where { $0.travelPartyID.eq(loser.id) }
        .update { $0.travelPartyID = #bind(survivor.id) }
        .execute(db)
      try Idea.where { $0.travelPartyID.eq(loser.id) }
        .update { $0.travelPartyID = #bind(survivor.id) }
        .execute(db)
      try MapRegion.where { $0.travelPartyID.eq(loser.id) }
        .update { $0.travelPartyID = #bind(survivor.id) }
        .execute(db)
      try Tag.where { $0.travelPartyID.eq(loser.id) }
        .update { $0.travelPartyID = #bind(survivor.id) }
        .execute(db)
      try Trip.where { $0.travelPartyID.eq(loser.id) }
        .update { $0.travelPartyID = #bind(survivor.id) }
        .execute(db)
      try IdeaEvaluation.where { $0.travelPartyID.eq(loser.id) }
        .update { $0.travelPartyID = #bind(survivor.id) }
        .execute(db)
      try TravelProfile.where { $0.travelPartyID.eq(loser.id) }
        .update { $0.travelPartyID = #bind(survivor.id) }
        .execute(db)
    }
  }
}

public enum TravelPartyError: Error {
  case creationFailed
}
