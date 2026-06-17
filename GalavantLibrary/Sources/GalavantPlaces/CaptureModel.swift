import Dependencies
import Foundation
import GalavantCapture
import GalavantSchema
import SQLiteData

/// The capture flow's view-model — drives the share-extension confirm sheet
/// (Jon's choice: vet captures at the source). It parses the shared page, refines
/// the location via Apple Maps, exposes an **editable** draft for confirm-and-tweak,
/// and saves to the app-group database. Lives in the package (not the extension
/// shell) so the parse→match→save logic is testable with an in-memory DB and
/// fixture clients; the extension only hosts the SwiftUI view over it.
///
/// Single-hop by design (M4c): the place's `websiteURL` is preserved on the saved
/// idea so the app can take the deferred second enrichment hop later.
@MainActor
@Observable
public final class CaptureModel {
  public enum Phase: Equatable, Sendable {
    case preparing
    case ready
    case saving
    case saved
    case failed(String)
  }

  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.placeMatcher) private var placeMatcher
  @ObservationIgnored @Dependency(\.uuid) private var uuid

  private let html: String
  private let sourceURL: URL?

  public private(set) var phase: Phase = .preparing
  /// The editable idea the confirm sheet binds to (name/kind/notes/url/…).
  public var draft = Idea.Draft()
  /// Carry-over signals the `Idea` schema doesn't hold yet (images, hours, the
  /// second-hop `websiteURL`) — kept for the deferred app-side enrichment.
  public private(set) var captured: CapturedPlace?

  public init(html: String, sourceURL: URL?) {
    self.html = html
    self.sourceURL = sourceURL
  }

  /// Parse the page and refine its location. Idempotent-ish — call once on appear.
  public func prepare() async {
    let page = PageParser.parse(html: html, sourceURL: sourceURL)
    let captured = CapturedPlace.from(page, id: uuid())
    var draft = captured.draft

    if let match = await placeMatcher.match(page) {
      draft.latitude = match.coordinate.latitude
      draft.longitude = match.coordinate.longitude
      // Confirm-and-tweak: only fill what the page left blank (like search-first).
      if draft.name.isEmpty, let name = match.name { draft.name = name }
      if draft.address == nil, let address = match.address { draft.address = address }
    }

    self.captured = captured
    self.draft = draft
    self.phase = .ready
  }

  /// Save the (possibly edited) draft into the shared pool under the default
  /// travel party, so it rides the travel-party CloudKit share (ADR-0003).
  public func save() async {
    phase = .saving
    // Capture only Sendable scalars into the DB write — `Idea.Draft` itself isn't
    // Sendable (the @Table-generated type), so rebuild it inside the closure.
    let id = draft.id
    let name = draft.name
    let notes = draft.notes
    let kind = draft.kind
    let regionName = draft.regionName
    let address = draft.address
    let phone = draft.phone
    let latitude = draft.latitude
    let longitude = draft.longitude
    let url = draft.url
    do {
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(
            id: id,
            name: name,
            notes: notes,
            kind: kind,
            regionName: regionName,
            address: address,
            phone: phone,
            latitude: latitude,
            longitude: longitude,
            url: url,
            travelPartyID: party.id
          )
        }
        .execute(db)
      }
      phase = .saved
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}
