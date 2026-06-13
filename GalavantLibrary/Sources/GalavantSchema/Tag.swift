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
  /// Reuse an existing tag with the same name (case-insensitive) or create one,
  /// so the household vocabulary stays consistent ("Michelin" not also "michelin").
  public static func findOrCreate(named name: String, in db: Database) throws -> Tag {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let existing = try Tag.all.fetchAll(db).first {
      $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
    }
    if let existing { return existing }
    let partyID = try TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try Tag.insert { Tag.Draft(id: id, name: trimmed, travelPartyID: partyID) }.execute(db)
    return try Tag.find(id).fetchOne(db)!
  }
}
