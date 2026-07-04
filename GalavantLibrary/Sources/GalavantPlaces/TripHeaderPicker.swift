import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// Drives the trip "romance" header picker (ADR-0032): seed a query from the trip,
/// search Unsplash, and — on selection — ping the ToS tracked-download endpoint and
/// persist the chosen photo's reference onto the `Trip`. Lives in the package (not
/// the app shell) so the seed/search/select logic is testable with a stubbed
/// `UnsplashClient` and an in-memory DB; the app hosts only the grid sheet + header
/// view. [[inject-io-boundaries-early]]
@MainActor
@Observable
public final class TripHeaderPicker {
  public enum Phase: Equatable, Sendable {
    case idle
    case searching
    case loaded
    case failed(String)
  }

  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.unsplashClient) private var unsplash

  public let tripID: Trip.ID

  /// The editable search query, seeded from the trip on init (name / primary region).
  public var query: String
  public private(set) var phase: Phase = .idle
  public private(set) var results: [UnsplashPhoto] = []

  /// Seed the query from what best names the trip's *place*: the primary region if
  /// the trip has one, else the trip name. A blank result leaves an empty query the
  /// user types into rather than an auto-search of nothing.
  public init(tripID: Trip.ID, tripName: String, primaryRegionName: String? = nil) {
    self.tripID = tripID
    let seed = (primaryRegionName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
      $0.isEmpty ? nil : $0
    }
    self.query = seed ?? tripName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Run the current query. No-op on a blank query (nothing to search); on transport
  /// failure surfaces `.failed` rather than throwing, so the sheet shows a retry
  /// state. A successful-but-empty result is `.loaded` with `results == []`.
  public func search() async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      results = []
      phase = .idle
      return
    }
    phase = .searching
    do {
      results = try await unsplash(query: trimmed)
      phase = .loaded
    } catch {
      results = []
      phase = .failed(error.localizedDescription)
    }
  }

  /// Commit a chosen photo as the trip's header. Order matters: ping the ToS
  /// tracked-download endpoint **first** (best-effort), then persist the reference.
  public func choose(_ photo: UnsplashPhoto) async {
    await unsplash.registerDownload(for: photo)
    let image = TripHeaderImage(
      url: photo.regularURL,
      color: photo.color,
      photographerName: photo.photographerName.isEmpty ? nil : photo.photographerName,
      photographerUsername: photo.photographerUsername.isEmpty ? nil : photo.photographerUsername
    )
    try? await database.write { [tripID] db in
      try Trip.setHeaderImage(image, tripID: tripID, in: db)
    }
  }

  /// Remove the trip's header (back to the plain title).
  public func clear() async {
    try? await database.write { [tripID] db in
      try Trip.setHeaderImage(nil, tripID: tripID, in: db)
    }
  }
}
