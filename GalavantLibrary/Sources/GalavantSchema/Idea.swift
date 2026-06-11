import Foundation
import SQLiteData

@Table
public struct Idea: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name = ""
  public var notes = ""
  public var regionName: String?
  public var latitude: Double?
  public var longitude: Double?
  public var householdID: Household.ID?

  public init(
    id: UUID,
    name: String = "",
    notes: String = "",
    regionName: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    householdID: Household.ID? = nil
  ) {
    self.id = id
    self.name = name
    self.notes = notes
    self.regionName = regionName
    self.latitude = latitude
    self.longitude = longitude
    self.householdID = householdID
  }
}
