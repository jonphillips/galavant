import Dependencies
import Foundation
import GalavantSchema
import Observation
import SQLiteData

@MainActor
@Observable
final class RegionManagementSettingsModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @FetchAll(MapRegion.order(by: \.name)) var regions
  @ObservationIgnored @FetchAll(TripRegion.all) private var tripRegions

  var selectedRegionID: MapRegion.ID?

  func tripUseDescription(for region: MapRegion) -> String {
    let count = Set(tripRegions.filter { $0.regionID == region.id }.map(\.tripID)).count
    return count == 1 ? "Used in 1 trip" : "Used in \(count) trips"
  }

  func deleteRegions(at offsets: IndexSet) {
    let ids = offsets.map { regions[$0].id }
    withErrorReporting {
      try database.write { db in
        // These are loose UUID relationships by design. Clear each projection in
        // the same write so a deleted region cannot linger in a trip/day lens.
        try TripDayRegion.where { $0.regionID.in(ids) }.delete().execute(db)
        try TripRegion.where { $0.regionID.in(ids) }.delete().execute(db)
        try MapRegion.where { $0.id.in(ids) }.delete().execute(db)
      }
    }
    if let selectedRegionID, ids.contains(selectedRegionID) {
      self.selectedRegionID = nil
    }
  }

  func rename(_ region: MapRegion, to name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    withErrorReporting {
      try database.write { db in
        try MapRegion.find(region.id).update { $0.name = #bind(name) }.execute(db)
      }
    }
  }
}
