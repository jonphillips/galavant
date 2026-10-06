import Dependencies
import CasePaths
import GalavantSchema
import Observation
import SQLiteData

@MainActor
@Observable
final class TripDocumentsModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @FetchAll private var fetchedDocuments: [TripDocument]

  let tripID: Trip.ID
  var destination: Destination?
  var errorMessage: String?

  @CasePathable
  enum Destination {
    case add
    case rename(TripDocument)
    case confirmDelete(TripDocument)
  }

  init(tripID: Trip.ID) {
    self.tripID = tripID
    _fetchedDocuments = FetchAll(
      TripDocument.where { $0.tripID.eq(tripID) }
        .order { ($0.createdAt.desc(), $0.id) }
    )
  }

  var documents: [TripDocument] { fetchedDocuments }

  func add(title: String, body: String) throws {
    _ = try database.write { db in
      try TripDocument.add(tripID: tripID, title: title, body: body, origin: .pasted, in: db)
    }
  }

  func rename(_ documentID: TripDocument.ID, title: String) throws {
    _ = try database.write { db in
      try TripDocument.rename(documentID, title: title, in: db)
    }
  }

  func delete(_ documentID: TripDocument.ID) throws {
    _ = try database.write { db in
      try TripDocument.delete(documentID, in: db)
    }
  }
}
