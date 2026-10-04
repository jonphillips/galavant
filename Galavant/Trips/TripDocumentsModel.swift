import Dependencies
import GalavantSchema
import Observation
import SQLiteData

@MainActor
@Observable
final class TripDocumentsModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @FetchAll(TripDocument.all) private var allDocuments

  let tripID: Trip.ID

  init(tripID: Trip.ID) {
    self.tripID = tripID
  }

  var documents: [TripDocument] {
    TripDocument.newestFirst(allDocuments.filter { $0.tripID == tripID })
  }

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
