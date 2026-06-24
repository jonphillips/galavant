import Foundation
import GalavantCapture

/// A place shared *as a location* rather than a web page — an Apple Maps `MKMapItem`
/// or a vCard (ADR-0020). Domain-free, like `ParsedPage`: the extension decodes the
/// map item / vCard (the I/O) into this, and `CaptureModel` seeds the existing
/// capture pipeline from it. No MapKit/Contacts here, so the seam stays portable and
/// the synthesis is unit-testable.
public struct SharedLocation: Equatable, Sendable {
  public var name: String
  public var latitude: Double?
  public var longitude: Double?
  public var street: String?
  public var locality: String?
  public var region: String?
  public var postalCode: String?
  public var country: String?
  public var phone: String?
  public var websiteURL: URL?
  /// Apple Maps' persistent place identity (`MKMapItem.identifier`), when the share
  /// carried one — the ADR-0019 dedup key, which a vCard can't supply.
  public var mapItemIdentifier: String?

  public init(
    name: String,
    latitude: Double? = nil,
    longitude: Double? = nil,
    street: String? = nil,
    locality: String? = nil,
    region: String? = nil,
    postalCode: String? = nil,
    country: String? = nil,
    phone: String? = nil,
    websiteURL: URL? = nil,
    mapItemIdentifier: String? = nil
  ) {
    self.name = name
    self.latitude = latitude
    self.longitude = longitude
    self.street = street
    self.locality = locality
    self.region = region
    self.postalCode = postalCode
    self.country = country
    self.phone = phone
    self.websiteURL = websiteURL
    self.mapItemIdentifier = mapItemIdentifier
  }

  /// Synthesize the neutral `ParsedPage` the capture pipeline expects. The Maps/vCard
  /// name is authoritative (`titleIsStructured: true`), so a confident Apple Maps
  /// match corroborates rather than overrides it. A coordinate is carried through
  /// when present; absent one (the usual vCard case) the matcher geocodes from the
  /// name + locality.
  public func parsedPage(capturedAt: Date) -> ParsedPage {
    let coordinate = zip(latitude, longitude).map { ParsedCoordinate(latitude: $0, longitude: $1) }
    return ParsedPage(
      sourceURL: nil,
      title: name.isEmpty ? nil : name,
      titleIsStructured: !name.isEmpty,
      phone: phone,
      websiteURL: websiteURL,
      coordinate: coordinate,
      address: ParsedAddress(
        street: street,
        locality: locality,
        region: region,
        postalCode: postalCode,
        country: country
      ),
      capturedAt: capturedAt
    )
  }
}

/// `zip` for two optionals: `.some` only when both are present.
private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
  guard let a, let b else { return nil }
  return (a, b)
}
