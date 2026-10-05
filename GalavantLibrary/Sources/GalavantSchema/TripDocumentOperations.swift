import Dependencies
import Foundation
import SQLiteData

public enum TripDocumentError: Error, Equatable, Sendable {
  case tooLarge
  case emptyBody
}

extension TripDocument {
  /// Add a trip document. Bodies are capped well below CloudKit's record limit.
  @discardableResult
  public static func add(
    tripID: Trip.ID,
    title: String,
    body: String,
    origin: TripDocumentOrigin,
    now suppliedDate: Date? = nil,
    in db: Database
  ) throws -> TripDocument.ID {
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TripDocumentError.emptyBody
    }
    guard body.utf8.count <= 512_000 else { throw TripDocumentError.tooLarge }
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date
    let now = suppliedDate ?? date.now
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let finalTitle = trimmedTitle.isEmpty
      ? "Document — \(now.formatted(date: .abbreviated, time: .omitted))"
      : trimmedTitle
    let document = TripDocument(
      id: uuid(), tripID: tripID, title: finalTitle, body: body, origin: origin, createdAt: now)
    try TripDocument.insert { TripDocument.Draft(document) }.execute(db)
    return document.id
  }

  public static func rename(_ id: TripDocument.ID, title: String, in db: Database) throws {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    try TripDocument.find(id).update { $0.title = #bind(trimmed) }.execute(db)
  }

  public static func delete(_ id: TripDocument.ID, in db: Database) throws {
    try TripDocument.find(id).delete().execute(db)
  }
}
