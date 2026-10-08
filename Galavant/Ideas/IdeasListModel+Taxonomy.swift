import CoreLocation
import Dependencies
import GalavantSchema
import MapKit
import SQLiteData

/// Region management writes from Ideas' map/filter surface.
extension IdeasListModel {
  func deleteRegions(at offsets: IndexSet) {
    let ids = offsets.map { regions[$0].id }
    withErrorReporting {
      try database.write { db in
        try MapRegion.where { $0.id.in(ids) }.delete().execute(db)
      }
    }
    if let selected = selectedRegionID, ids.contains(selected) {
      selectedRegionID = nil
    }
  }

  func renameRegion(_ region: MapRegion, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    withErrorReporting {
      try database.write { db in
        try MapRegion.find(region.id).update { $0.name = trimmed }.execute(db)
      }
    }
  }

  func saveRegion(named name: String, center: CLLocationCoordinate2D, span: MKCoordinateSpan) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    withErrorReporting {
      try database.write { db in
        let partyID = try TravelParty.ensureDefault(in: db).id
        try MapRegion.insert {
          MapRegion(
            id: UUID(),
            name: trimmed,
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            latitudeDelta: span.latitudeDelta,
            longitudeDelta: span.longitudeDelta,
            travelPartyID: partyID
          )
        }
        .execute(db)
      }
    }
  }
}
