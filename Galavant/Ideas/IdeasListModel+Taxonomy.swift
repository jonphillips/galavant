import CoreLocation
import Dependencies
import GalavantSchema
import MapKit
import SQLiteData

/// Region and tag management writes (rename, delete, define-from-map) — the
/// taxonomy-editing surface behind the Manage Regions / Manage Tags sheets. Split
/// out of `IdeasListModel` so the core file stays focused on the pool projection.
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

  func deleteTags(at offsets: IndexSet) {
    let ids = offsets.map { sortedTags[$0].id }
    withErrorReporting {
      try database.write { db in
        try Tag.where { $0.id.in(ids) }.delete().execute(db)
        // tagID is a loose UUID (not a SQL FK), so clean up join rows by hand.
        try IdeaTag.where { $0.tagID.in(ids) }.delete().execute(db)
      }
    }
    selectedTagIDs.subtract(ids)
  }

  func renameTag(_ tag: Tag, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    withErrorReporting {
      try database.write { db in
        try Tag.find(tag.id).update { $0.name = trimmed }.execute(db)
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
          MapRegion.Draft(
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
