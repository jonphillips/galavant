import Foundation
import SQLiteData

@Table
public struct Household: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name = "Our Household"

  public init(id: UUID, name: String = "Our Household") {
    self.id = id
    self.name = name
  }
}

extension Household {
  public static func ensure(in db: Database) throws -> Household {
    if let existing = try Household.order(by: \.id).fetchOne(db) {
      return existing
    }
    try Household.insert { Household.Draft(name: "Our Household") }.execute(db)
    guard let created = try Household.order(by: \.id).fetchOne(db) else {
      throw HouseholdError.creationFailed
    }
    return created
  }
}

public enum HouseholdError: Error {
  case creationFailed
}
