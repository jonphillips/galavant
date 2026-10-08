import Foundation
import SQLiteData

/// A free-form household label ("Michelin", "kid-friendly", "rainy-day").
/// First-class so the travel party shares one vocabulary and a tag can be
/// renamed everywhere. Hangs off the travel party (ADR-0007 single-FK).
@Table
public struct Tag: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name = ""
  public var travelPartyID: TravelParty.ID?

  public init(id: UUID, name: String = "", travelPartyID: TravelParty.ID? = nil) {
    self.id = id
    self.name = name
    self.travelPartyID = travelPartyID
  }
}

extension Tag {
  struct LogicalKey: Hashable {
    let travelPartyID: TravelParty.ID?
    let normalizedName: String
  }

  static func logicalKey(_ tag: Tag) -> LogicalKey {
    LogicalKey(
      travelPartyID: tag.travelPartyID,
      normalizedName: tag.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    )
  }

  /// Repoint joins, collapse duplicate idea/tag pairs, then remove duplicate tags.
  /// Call from the owning write so all three operations commit atomically.
  @discardableResult
  public static func convergeDuplicates(in db: Database) throws -> [ID: ID] {
    let tags = try Tag.all.fetchAll(db)
    let groups = Dictionary(grouping: tags, by: logicalKey)
    var survivorByLoser: [ID: ID] = [:]

    for group in groups.values {
      let converged = group.convergingByKey { _ in true }
      guard !converged.losers.isEmpty, let survivor = converged.survivors.first else { continue }
      let loserIDs = converged.losers.map(\.id)
      for loserID in loserIDs {
        try IdeaTag.where { $0.tagID.eq(loserID) }
          .update { $0.tagID = #bind(survivor.id) }
          .execute(db)
        survivorByLoser[loserID] = survivor.id
      }
      let joins = try IdeaTag.where { $0.tagID.eq(survivor.id) }.fetchAll(db)
      for loser in joins.convergingByKey({ [$0.ideaID, $0.tagID] }).losers {
        try IdeaTag.find(loser.id).delete().execute(db)
      }
      try Tag.where { $0.id.in(loserIDs) }.delete().execute(db)
    }
    return survivorByLoser
  }

  /// Reuse an existing tag with the same name (case-insensitive) or create one,
  /// so the household vocabulary stays consistent ("Michelin" not also "michelin").
  public static func findOrCreate(named name: String, in db: Database) throws -> Tag {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let partyID = try TravelParty.ensureDefault(in: db).id
    _ = try convergeDuplicates(in: db)
    let existing = try Tag.all.fetchAll(db).first {
      $0.travelPartyID == partyID
        && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
          .caseInsensitiveCompare(trimmed) == .orderedSame
    }
    if let existing { return existing }
    let id = UUID()
    try Tag.insert {
      Tag.Draft(Tag(id: id, name: trimmed, travelPartyID: partyID))
    }
    .execute(db)
    return try Tag.find(id).fetchOne(db)!
  }

  @discardableResult
  public static func rename(_ id: ID, to name: String, in db: Database) throws -> Tag? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return try Tag.find(id).fetchOne(db) }
    _ = try convergeDuplicates(in: db)
    guard try Tag.find(id).fetchOne(db) != nil else { return nil }
    try Tag.find(id).update { $0.name = #bind(trimmed) }.execute(db)
    let mapping = try convergeDuplicates(in: db)
    let survivorID = mapping[id] ?? id
    try Tag.find(survivorID).update { $0.name = #bind(trimmed) }.execute(db)
    return try Tag.find(survivorID).fetchOne(db)
  }

  public static func delete(_ ids: [ID], in db: Database) throws {
    guard !ids.isEmpty else { return }
    try IdeaTag.where { $0.tagID.in(ids) }.delete().execute(db)
    try Tag.where { $0.id.in(ids) }.delete().execute(db)
  }

  @discardableResult
  public static func deleteUnused(in db: Database) throws -> Int {
    let tags = try Tag.all.fetchAll(db)
    let usedIDs = Set(try IdeaTag.all.fetchAll(db).map(\.tagID))
    let unusedIDs = tags.map(\.id).filter { !usedIDs.contains($0) }
    try delete(unusedIDs, in: db)
    return unusedIDs.count
  }
}
