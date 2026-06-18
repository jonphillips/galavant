import Foundation
import SQLiteData

/// One stored image attached to an `Idea` (ADR-0009 §3). Images live in their own
/// table so `ideas` rows stay light and don't drag bytes on every list/map query.
/// The single real foreign key is to `Idea` (ON DELETE CASCADE — the image dies
/// with its idea), honoring the single-FK sharing rule (ADR-0007); it rides the
/// travel-party CloudKit share through that idea.
///
/// `display`/`thumbnail` hold the **compressed** bytes (the canonical, syncable
/// form, ADR-0009 §5) produced by `GalavantImaging.ImageProcessing`; the decoded
/// bitmap is a device-local cache the UI re-derives. `sourceURL` is provenance and
/// the idempotency key for re-enrichment (don't re-store the same scraped image).
///
/// *Trip header images (M5 Unsplash "romance") will need their own table or a
/// loose-owner generalization — the single-FK rule precludes one row FK-ing both
/// an `Idea` and a `Trip`. This table is Idea-scoped for M4.*
@Table
public struct ImageAsset: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var ideaID: Idea.ID
  /// Display-tier compressed bytes (~1600 px, ≈300 KB) — what the UI renders.
  public var display: Data
  /// Thumbnail compressed bytes — for cells and map pins.
  public var thumbnail: Data
  /// Where the image came from (the scraped URL), for provenance + de-duplication.
  public var sourceURL: String?
  /// Order within an idea's images (header excluded — the header floats out).
  public var sortRank: Int
  /// The chosen header for the idea. At most one per idea is `true`.
  public var isHeader: Bool

  public init(
    id: UUID,
    ideaID: Idea.ID,
    display: Data,
    thumbnail: Data,
    sourceURL: String? = nil,
    sortRank: Int = 0,
    isHeader: Bool = false
  ) {
    self.id = id
    self.ideaID = ideaID
    self.display = display
    self.thumbnail = thumbnail
    self.sourceURL = sourceURL
    self.sortRank = sortRank
    self.isHeader = isHeader
  }
}

extension ImageAsset {
  /// Store an image for an idea, idempotent on `(ideaID, sourceURL)`: a second
  /// store of the same scraped URL updates the existing row's bytes rather than
  /// duplicating (so re-enrichment is safe to re-run). When `sourceURL` is nil
  /// (e.g. a Photos pick) every call inserts. The first image stored for an idea
  /// becomes its header unless one is already set; `asHeader` forces it. Filtered/
  /// ranked in Swift — an idea carries a handful of images.
  @discardableResult
  public static func store(
    ideaID: Idea.ID,
    display: Data,
    thumbnail: Data,
    sourceURL: String? = nil,
    asHeader: Bool = false,
    id: UUID,
    in db: Database
  ) throws -> ImageAsset {
    let existing = try ImageAsset.where { $0.ideaID.eq(ideaID) }.fetchAll(db)

    if let sourceURL,
      let match = existing.first(where: { $0.sourceURL == sourceURL })
    {
      try ImageAsset.find(match.id)
        .update {
          $0.display = display
          $0.thumbnail = thumbnail
        }
        .execute(db)
      if asHeader { try setHeader(match.id, ideaID: ideaID, in: db) }
      return try ImageAsset.find(match.id).fetchOne(db) ?? match
    }

    let makeHeader = asHeader || !existing.contains { $0.isHeader }
    let rank = (existing.map(\.sortRank).max() ?? -1) + 1
    try ImageAsset.insert {
      ImageAsset.Draft(
        id: id,
        ideaID: ideaID,
        display: display,
        thumbnail: thumbnail,
        sourceURL: sourceURL,
        sortRank: rank,
        isHeader: makeHeader
      )
    }
    .execute(db)
    if makeHeader { try setHeader(id, ideaID: ideaID, in: db) }
    guard let created = try ImageAsset.find(id).fetchOne(db) else {
      throw ImageAssetError.creationFailed
    }
    return created
  }

  /// Make one image the idea's header, clearing the flag on the idea's others
  /// (at most one header per idea). No-op if the image isn't this idea's.
  public static func setHeader(
    _ imageID: ImageAsset.ID,
    ideaID: Idea.ID,
    in db: Database
  ) throws {
    let images = try ImageAsset.where { $0.ideaID.eq(ideaID) }.fetchAll(db)
    guard images.contains(where: { $0.id == imageID }) else { return }
    for image in images where image.isHeader && image.id != imageID {
      try ImageAsset.find(image.id).update { $0.isHeader = false }.execute(db)
    }
    try ImageAsset.find(imageID).update { $0.isHeader = true }.execute(db)
  }

  /// An idea's images, header first, then by `sortRank`.
  public static func images(forIdea ideaID: Idea.ID, in db: Database) throws -> [ImageAsset] {
    try ImageAsset.where { $0.ideaID.eq(ideaID) }.fetchAll(db)
      .sorted { lhs, rhs in
        lhs.isHeader == rhs.isHeader ? lhs.sortRank < rhs.sortRank : lhs.isHeader
      }
  }

  /// The idea's header image, if any (falls back to the lowest-rank image when no
  /// flag is set — e.g. older rows).
  public static func header(forIdea ideaID: Idea.ID, in db: Database) throws -> ImageAsset? {
    try images(forIdea: ideaID, in: db).first
  }
}

public enum ImageAssetError: Error {
  case creationFailed
}
