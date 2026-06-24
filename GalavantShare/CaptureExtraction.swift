import Contacts
import Foundation
import GalavantPlaces
import MapKit
import UniformTypeIdentifiers

/// Pulls the shared item out of the extension context. A *location* share (Apple
/// Maps map item, then a vCard — ADR-0020) is preferred and seeds the capture
/// pipeline directly. Otherwise it's a *page* share: the JS preprocessing results
/// (Safari's rendered DOM via `ExtensionPreProcessing.js`), falling back to a plain
/// shared URL whose HTML we fetch with a Safari-like User-Agent.
enum CaptureExtraction {
  struct Input {
    var html: String = ""
    var url: URL?
    /// A shared place (Maps/vCard); when set, ShareViewController seeds a location
    /// capture and `html`/`url` are unused.
    var location: SharedLocation?
  }

  static func input(from context: NSExtensionContext?) async -> Input {
    let items = (context?.inputItems as? [NSExtensionItem]) ?? []
    let providers = items.flatMap { $0.attachments ?? [] }

    // 0. A location share (ADR-0020) — Maps map item first (richest), then a vCard.
    if let location = await location(from: providers) {
      return Input(location: location)
    }

    // 1. Rendered DOM from the JS preprocessor.
    for provider in providers
    where provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
      guard
        let loaded = try? await provider.loadItem(
          forTypeIdentifier: UTType.propertyList.identifier
        ),
        let results = loaded as? NSDictionary,
        let js = results[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
      else { continue }
      let html = js["html"] as? String ?? ""
      let url = (js["url"] as? String).flatMap(URL.init(string:))
      if !html.isEmpty { return Input(html: html, url: url) }
    }

    // 2. Fallback: a bare URL share — fetch the page ourselves.
    for provider in providers
    where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      guard
        let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
        let url = loaded as? URL
      else { continue }
      return Input(html: await fetchHTML(url), url: url)
    }

    return Input()
  }

  // MARK: - Location shares (ADR-0020)

  /// A shared place, preferring an Apple Maps `MKMapItem` (a real coordinate + the
  /// persistent `identifier` for free) over a vCard (geocoded from its address).
  private static func location(from providers: [NSItemProvider]) async -> SharedLocation? {
    for provider in providers where provider.canLoadObject(ofClass: MKMapItem.self) {
      if let location = await mapItemLocation(provider) {
        return location
      }
    }
    for provider in providers
    where provider.hasItemConformingToTypeIdentifier(UTType.vCard.identifier) {
      guard
        let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.vCard.identifier)
      else { continue }
      let data = (loaded as? Data) ?? (loaded as? URL).flatMap { try? Data(contentsOf: $0) }
      if let data, let location = sharedLocation(fromVCard: data) { return location }
    }
    return nil
  }

  /// Bridge `NSItemProvider`'s completion-handler `loadObject` (the async overload
  /// doesn't apply to `MKMapItem` here) to async, mapping to the Sendable
  /// `SharedLocation` *inside* the handler — `MKMapItem` itself isn't Sendable.
  private static func mapItemLocation(_ provider: NSItemProvider) async -> SharedLocation? {
    await withCheckedContinuation { continuation in
      provider.loadObject(ofClass: MKMapItem.self) { object, _ in
        continuation.resume(returning: (object as? MKMapItem).map(sharedLocation(from:)))
      }
    }
  }

  /// Map an Apple Maps item to our location seed, using the iOS 26 `location` /
  /// `addressRepresentations` / `identifier` API (mirrors `Place.init(mapItem:)`).
  /// Address parts are left to the capture-flow match to fill canonically; we keep
  /// the city/region as an offline-resilient fallback.
  private static func sharedLocation(from item: MKMapItem) -> SharedLocation {
    SharedLocation(
      name: item.name ?? item.addressRepresentations?.cityName ?? "",
      latitude: item.location.coordinate.latitude,
      longitude: item.location.coordinate.longitude,
      locality: item.addressRepresentations?.cityName,
      region: item.addressRepresentations?.regionName,
      phone: item.phoneNumber,
      websiteURL: item.url,
      mapItemIdentifier: item.identifier?.rawValue
    )
  }

  /// Map a vCard's first contact to a location seed — name + postal address (which the
  /// capture-flow match geocodes, since a vCard carries no coordinate or Maps identity).
  private static func sharedLocation(fromVCard data: Data) -> SharedLocation? {
    guard
      let contacts = try? CNContactVCardSerialization.contacts(with: data),
      let contact = contacts.first
    else { return nil }
    let name = placeName(from: contact)
    guard !name.isEmpty else { return nil }
    let postal = contact.postalAddresses.first?.value
    return SharedLocation(
      name: name,
      street: postal?.street.nilIfBlank,
      locality: postal?.city.nilIfBlank,
      region: postal?.state.nilIfBlank,
      postalCode: postal?.postalCode.nilIfBlank,
      country: postal?.country.nilIfBlank,
      phone: contact.phoneNumbers.first?.value.stringValue,
      websiteURL: contact.urlAddresses.first.flatMap { URL(string: $0.value as String) }
    )
  }

  /// A place vCard names the place either as an organization or as the contact name.
  private static func placeName(from contact: CNContact) -> String {
    if !contact.organizationName.isEmpty { return contact.organizationName }
    return CNContactFormatter.string(from: contact, style: .fullName) ?? ""
  }

  // MARK: - Page fallback

  private static func fetchHTML(_ url: URL) async -> String {
    var request = URLRequest(url: url)
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }
}

private extension String {
  /// `nil` when empty/whitespace — vCard fields come back as "" rather than absent.
  var nilIfBlank: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}
