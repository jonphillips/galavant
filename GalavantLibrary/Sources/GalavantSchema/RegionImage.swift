import Foundation
import SQLiteData

/// One stored "romance" photo for a `MapRegion` — the ambient header the iPad
/// Journey panel shows when a stay in that region is selected (M10). Region-scoped:
/// the single real foreign key is to `MapRegion` (ON DELETE CASCADE — the photo
/// dies with its region), honoring the single-FK sharing rule (ADR-0007); it rides
/// the region's travel-party CloudKit share through that edge. At most one row per
/// region — `set(...)` replaces rather than accumulates.
///
/// **Bytes for both sources** (M10 decision): a chosen Unsplash photo is downloaded
/// and processed exactly like a Photos-library pick, so one storage + render path
/// serves both. `display`/`thumbnail` hold the compressed tiers produced by
/// `GalavantImaging.ImageProcessing`; the decoded bitmap is a device-local cache the
/// UI re-derives. `sourceURL` is provenance; the photographer fields carry the
/// Unsplash attribution the ToS requires the UI to display (nil for a Photos pick).
///
/// This is the Idea-scoped `ImageAsset`'s region-scoped sibling — kept a separate
/// table (not columns on `MapRegion`) so region list/map queries stay light and
/// never drag BLOBs, the same reason `ImageAsset` is split from `Idea`.
@Table
public struct RegionImage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var regionID: MapRegion.ID
  /// Display-tier compressed bytes (~1600 px) — what the panel renders.
  public var display: Data
  /// Thumbnail compressed bytes — for the compact panel state.
  public var thumbnail: Data
  /// Where the image came from (the Unsplash CDN URL), for provenance. Nil for a
  /// Photos-library pick.
  public var sourceURL: String?
  /// Unsplash attribution (ToS): the photographer's display name. Nil for a Photos
  /// pick.
  public var photographerName: String?
  /// Unsplash attribution (ToS): the photographer's username, for the profile link.
  public var photographerUsername: String?

  public init(
    id: UUID,
    regionID: MapRegion.ID,
    display: Data,
    thumbnail: Data,
    sourceURL: String? = nil,
    photographerName: String? = nil,
    photographerUsername: String? = nil
  ) {
    self.id = id
    self.regionID = regionID
    self.display = display
    self.thumbnail = thumbnail
    self.sourceURL = sourceURL
    self.photographerName = photographerName
    self.photographerUsername = photographerUsername
  }
}

extension RegionImage {
  /// Set (replace) a region's romance photo. A region carries at most one, so this
  /// deletes any existing row for the region before inserting — a re-pick swaps the
  /// image rather than accumulating.
  @discardableResult
  public static func set(
    regionID: MapRegion.ID,
    display: Data,
    thumbnail: Data,
    sourceURL: String? = nil,
    photographerName: String? = nil,
    photographerUsername: String? = nil,
    id: UUID,
    in db: Database
  ) throws -> RegionImage {
    try RegionImage.where { $0.regionID.eq(regionID) }.delete().execute(db)
    try RegionImage.insert {
      RegionImage.Draft(
        RegionImage(
          id: id,
          regionID: regionID,
          display: display,
          thumbnail: thumbnail,
          sourceURL: sourceURL,
          photographerName: photographerName,
          photographerUsername: photographerUsername
        )
      )
    }
    .execute(db)
    guard let created = try RegionImage.find(id).fetchOne(db) else {
      throw RegionImageError.creationFailed
    }
    return created
  }

  /// The region's romance photo, if it has one.
  public static func image(forRegion regionID: MapRegion.ID, in db: Database) throws -> RegionImage? {
    try RegionImage.where { $0.regionID.eq(regionID) }.fetchAll(db).first
  }

  /// Remove a region's romance photo (back to no image).
  public static func clear(forRegion regionID: MapRegion.ID, in db: Database) throws {
    try RegionImage.where { $0.regionID.eq(regionID) }.delete().execute(db)
  }
}

public enum RegionImageError: Error {
  case creationFailed
}
