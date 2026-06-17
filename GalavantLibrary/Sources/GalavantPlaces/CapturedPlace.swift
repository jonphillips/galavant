import Foundation
import GalavantCapture
import GalavantSchema

/// A scraped page turned toward the domain: the `Idea.Draft` the capture form will
/// present, plus the signals the `Idea` schema doesn't (yet) hold — images,
/// socials, opening hours, the two-hop `websiteURL` — kept alongside rather than
/// dropped, so M4c/M4d (image storage per ADR-0009, booking/hours) can use them
/// without re-parsing. This is the domain bridge: the capture *engine* stays
/// `Idea`-free; the mapping lives here, where MapKit and the schema already meet.
///
/// Not `Sendable`/`Equatable`: it wraps `Idea.Draft`, the `@Table`-generated draft
/// type, which is neither. The capture flow builds and consumes it on the main
/// actor, so that's not a constraint in practice.
public struct CapturedPlace {
  /// The pre-filled idea — confirm-and-tweak, exactly like search-first capture.
  public var draft: Idea.Draft
  /// Candidate images, best-first (header candidate is `imageURLs.first`).
  public var imageURLs: [URL]
  /// Social profile links surfaced by the page (`sameAs`).
  public var socialURLs: [URL]
  /// Raw opening-hours specs (weekday granularity), paired with `capturedAt`.
  public var openingHours: [String]
  /// When the page was parsed — opening hours and other facts rot.
  public var capturedAt: Date
  /// The page we captured from (the shared/origin URL).
  public var sourceURL: URL?
  /// The place's own site, when the page advertised one different from `sourceURL`
  /// — the unconsumed second-hop enrichment target (M4c).
  public var websiteURL: URL?

  public init(
    draft: Idea.Draft,
    imageURLs: [URL] = [],
    socialURLs: [URL] = [],
    openingHours: [String] = [],
    capturedAt: Date = Date(),
    sourceURL: URL? = nil,
    websiteURL: URL? = nil
  ) {
    self.draft = draft
    self.imageURLs = imageURLs
    self.socialURLs = socialURLs
    self.openingHours = openingHours
    self.capturedAt = capturedAt
    self.sourceURL = sourceURL
    self.websiteURL = websiteURL
  }
}

extension CapturedPlace {
  /// Map a parsed page to a captured place. Pure — the `id` (and owning party) are
  /// passed in so the caller controls them via `@Dependency(\.uuid)` rather than
  /// the mapping reaching for `UUID()` (BACKLOG: UUID dependency-control for new
  /// slices). MapKit matching refines the location afterward (PlaceMatching).
  public static func from(
    _ page: ParsedPage,
    id: UUID,
    travelPartyID: TravelParty.ID? = nil
  ) -> CapturedPlace {
    let address = page.address.oneLine
    let draft = Idea.Draft(
      id: id,
      name: page.title ?? "",
      notes: page.summary ?? "",
      kind: IdeaKind(schemaOrgTypes: page.schemaTypes),
      regionName: page.address.locality ?? page.address.region,
      address: address.isEmpty ? nil : address,
      phone: page.phone,
      latitude: page.coordinate?.latitude,
      longitude: page.coordinate?.longitude,
      url: page.websiteURL?.absoluteString ?? "",
      travelPartyID: travelPartyID
    )
    return CapturedPlace(
      draft: draft,
      imageURLs: page.imageURLs,
      socialURLs: page.socialURLs,
      openingHours: page.openingHours,
      capturedAt: page.capturedAt,
      sourceURL: page.sourceURL,
      websiteURL: page.websiteURL
    )
  }
}
