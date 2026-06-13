import CasePaths
import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// Owns the Trips list: the trips, their certainty sections, and the
/// create/edit destination. Reordering and persistence live here; the screen
/// stays presentation (STYLE thin-views rule).
@MainActor
@Observable
final class TripsListModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored @FetchAll(Trip.all) var trips

  var destination: Destination?

  @CasePathable
  enum Destination {
    case form(Trip.Draft)
  }

  /// Trips grouped and sorted by certainty (pure core).
  var sections: TripSections { Trip.sectioned(trips) }

  func addTripButtonTapped() {
    destination = .form(Trip.Draft())
  }

  func deleteTrips(_ trips: [Trip], at offsets: IndexSet) {
    let ids = offsets.map { trips[$0].id }
    withErrorReporting {
      try database.write { db in
        try Trip.where { $0.id.in(ids) }.delete().execute(db)
      }
    }
  }

  /// Persist a new someday-backlog order after a drag-to-reorder.
  func reorderSomeday(_ orderedIDs: [Trip.ID]) {
    withErrorReporting {
      try database.write { db in
        try Trip.reorderSomeday(orderedIDs, in: db)
      }
    }
  }
}
