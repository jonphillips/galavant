import Foundation

/// The neutral result of parsing one web page — everything the page told us about
/// a place, voted across its extraction layers (JSON-LD, OpenGraph, metatags,
/// microdata). Deliberately **domain-free**: it knows nothing about `Idea`/`Trip`
/// or MapKit, so the engine stays portable (BACKLOG "Portfolio extraction seams").
/// The app maps `ParsedPage` → `Idea`; the capture orchestrator uses `websiteURL`
/// (vs `sourceURL`) to decide whether to take a second enrichment hop.
public struct ParsedPage: Equatable, Sendable {
  /// The page we parsed (the shared/origin URL).
  public var sourceURL: URL?
  public var title: String?
  /// Whether `title` came from structured data (a JSON-LD/microdata `name`) rather
  /// than page chrome (og:/twitter:/`<title>`). A chrome title is a lower-confidence
  /// guess — often a marketing string we had to clip — so the capture flow lets a
  /// confident Apple Maps name override it, while a structured name is trusted as-is.
  public var titleIsStructured = false
  public var summary: String?
  public var phone: String?
  public var email: String?
  /// The place's *own* website, as advertised by the page (schema `url`, `og:url`,
  /// the business website link). When present **and different from `sourceURL`**
  /// it's the two-hop enrichment trigger — fetch and parse it too, then merge.
  public var websiteURL: URL?
  public var coordinate: ParsedCoordinate?
  public var address: ParsedAddress
  /// Candidate images, de-duplicated and filtered, best-first — the header
  /// candidate is `imageURLs.first` (the user can override).
  public var imageURLs: [URL]
  /// Social profile links (schema `sameAs`) — facebook/twitter/instagram etc.
  public var socialURLs: [URL]
  /// schema.org `@type` / `itemtype` strings seen on the page (e.g. `Restaurant`,
  /// `Hotel`). Generic — the app maps these to its own kind vocabulary.
  public var schemaTypes: [String]
  /// Raw opening-hours specifications (weekday granularity minimum). Hours rot, so
  /// they're paired with `capturedAt`. Kept verbatim; parsing into a structured
  /// schedule is a later concern.
  public var openingHours: [String]
  /// When this page was parsed — opening hours and other facts are dated.
  public var capturedAt: Date

  public init(
    sourceURL: URL? = nil,
    title: String? = nil,
    titleIsStructured: Bool = false,
    summary: String? = nil,
    phone: String? = nil,
    email: String? = nil,
    websiteURL: URL? = nil,
    coordinate: ParsedCoordinate? = nil,
    address: ParsedAddress = ParsedAddress(),
    imageURLs: [URL] = [],
    socialURLs: [URL] = [],
    schemaTypes: [String] = [],
    openingHours: [String] = [],
    capturedAt: Date = Date()
  ) {
    self.sourceURL = sourceURL
    self.title = title
    self.titleIsStructured = titleIsStructured
    self.summary = summary
    self.phone = phone
    self.email = email
    self.websiteURL = websiteURL
    self.coordinate = coordinate
    self.address = address
    self.imageURLs = imageURLs
    self.socialURLs = socialURLs
    self.schemaTypes = schemaTypes
    self.openingHours = openingHours
    self.capturedAt = capturedAt
  }

  /// True when nothing useful was found — the caller can fall back to manual entry
  /// or a map search rather than presenting an empty confirm form.
  public var isEmpty: Bool {
    title == nil && summary == nil && phone == nil && email == nil
      && websiteURL == nil && coordinate == nil && address.isEmpty
      && imageURLs.isEmpty && schemaTypes.isEmpty
  }
}

/// A geographic coordinate scraped from the page (schema `geo`,
/// `place:location:*`). Just the numbers — no MapKit.
public struct ParsedCoordinate: Equatable, Sendable {
  public var latitude: Double
  public var longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
}

/// Postal-address fields scraped from the page (schema `PostalAddress`,
/// `business:contact_data:*`). All optional; any subset may be present.
public struct ParsedAddress: Equatable, Sendable {
  public var street: String?
  public var locality: String?
  public var region: String?
  public var postalCode: String?
  public var country: String?

  public init(
    street: String? = nil,
    locality: String? = nil,
    region: String? = nil,
    postalCode: String? = nil,
    country: String? = nil
  ) {
    self.street = street
    self.locality = locality
    self.region = region
    self.postalCode = postalCode
    self.country = country
  }

  public var isEmpty: Bool {
    street == nil && locality == nil && region == nil
      && postalCode == nil && country == nil
  }

  /// A single-line address from the parts we have, comma-joined.
  public var oneLine: String {
    [street, locality, region, postalCode, country]
      .compactMap { $0 }
      .joined(separator: ", ")
  }
}
