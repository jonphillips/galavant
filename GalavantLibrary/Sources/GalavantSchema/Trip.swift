import Foundation
import SQLiteData

/// A trip in the planning pipeline. Its commitment level is the `Certainty`
/// pipeline (`someday → targeted → dated`), stored as flat columns so the list
/// can group and sort by it; read/write the domain enum via `certainty`
/// (Certainty.swift). `lengthInDays` is the stable duration fact — nothing
/// downstream keys off the calendar date (docs/trip-time-model.md). Single real
/// FK to TravelParty so it rides the share (ADR-0007).
@Table
public struct Trip: Identifiable, Equatable, Hashable, Sendable {
  public let id: UUID
  public var name = ""
  public var notes = ""
  public var certaintyStage: CertaintyStage = .someday
  /// Order within the `someday` backlog (lower = higher up). Meaningful only
  /// while `certaintyStage == .someday`; reset to 0 in the other stages.
  public var somedayRank = 0
  public var targetYear: Int?
  public var targetQuarter: Quarter?
  public var startDate: Date?
  public var lengthInDays = 7
  public var travelPartyID: TravelParty.ID?

  // MARK: Header image (ADR-0032, "romance")
  // A *reference* to an Unsplash photo, not stored bytes — we hotlink the CDN
  // (Unsplash's guideline) so a header is four small strings, not a BLOB. A
  // reference has no FK, so it sidesteps the single-FK sharing rule (ADR-0007)
  // that precludes reusing `ImageAsset`: these columns ride `Trip`'s existing
  // share edge to the second device. The bitmap is a device-local `AsyncImage`
  // cache; only the reference syncs.
  /// Unsplash `urls.regular` — the URL the header renders. Nil = no header chosen.
  public var headerImageURL: String?
  /// Unsplash `color` (hex) — the placeholder shown while loading or offline.
  public var headerImageColor: String?
  /// Attribution (ToS): the photographer's display name.
  public var headerPhotographerName: String?
  /// Attribution (ToS): the photographer's username, for the profile deep-link.
  public var headerPhotographerUsername: String?

  public init(
    id: UUID,
    name: String = "",
    notes: String = "",
    certaintyStage: CertaintyStage = .someday,
    somedayRank: Int = 0,
    targetYear: Int? = nil,
    targetQuarter: Quarter? = nil,
    startDate: Date? = nil,
    lengthInDays: Int = 7,
    travelPartyID: TravelParty.ID? = nil,
    headerImageURL: String? = nil,
    headerImageColor: String? = nil,
    headerPhotographerName: String? = nil,
    headerPhotographerUsername: String? = nil
  ) {
    self.id = id
    self.name = name
    self.notes = notes
    self.certaintyStage = certaintyStage
    self.somedayRank = somedayRank
    self.targetYear = targetYear
    self.targetQuarter = targetQuarter
    self.startDate = startDate
    self.lengthInDays = lengthInDays
    self.travelPartyID = travelPartyID
    self.headerImageURL = headerImageURL
    self.headerImageColor = headerImageColor
    self.headerPhotographerName = headerPhotographerName
    self.headerPhotographerUsername = headerPhotographerUsername
  }
}

extension Trip {
  /// The header image as a single value, folding the four flat columns into an
  /// all-or-nothing reference (ADR-0032). `nil` when no header URL is set — the
  /// trip screen shows a plain title; otherwise the render URL, its placeholder
  /// color, and the attribution the view is obligated to display. Setting flows
  /// the other way through `Trip.setHeaderImage`.
  public var headerImage: TripHeaderImage? {
    guard let headerImageURL else { return nil }
    return TripHeaderImage(
      url: headerImageURL,
      color: headerImageColor,
      photographerName: headerPhotographerName,
      photographerUsername: headerPhotographerUsername
    )
  }
}

/// A trip's chosen Unsplash header, as a value (ADR-0032). The persisted form is
/// four flat columns on `Trip`; this is how the picker hands one in and how the
/// header view reads one out. Domain-light — it holds a CDN reference plus the
/// attribution the Unsplash ToS requires the UI to show, never image bytes.
public struct TripHeaderImage: Equatable, Sendable {
  /// Unsplash `urls.regular` — the URL the header renders (hotlinked, not stored).
  public var url: String
  /// Unsplash `color` (hex) — the placeholder shown while loading / offline.
  public var color: String?
  /// The photographer's display name, for the "Photo by …" credit.
  public var photographerName: String?
  /// The photographer's username, for the profile deep-link in that credit.
  public var photographerUsername: String?

  public init(
    url: String,
    color: String? = nil,
    photographerName: String? = nil,
    photographerUsername: String? = nil
  ) {
    self.url = url
    self.color = color
    self.photographerName = photographerName
    self.photographerUsername = photographerUsername
  }
}
