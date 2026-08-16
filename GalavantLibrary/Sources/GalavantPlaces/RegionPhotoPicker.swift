import Dependencies
import Foundation
import GalavantImaging
import GalavantSchema
import SQLiteData

/// Drives the region "romance" photo picker (M10). Two sources, one stored form
/// (bytes): a chosen Unsplash photo is downloaded and processed exactly like a
/// Photos-library pick, then written as the region's single `RegionImage`. Lives in
/// the package (not the app shell) so the seed/search/select/store logic is testable
/// with a stubbed `UnsplashClient` + `ImageFetcher` and an in-memory DB; the app
/// hosts only the sheet + `PhotosPicker`. [[inject-io-boundaries-early]]
@MainActor
@Observable
public final class RegionPhotoPicker {
  public enum Phase: Equatable, Sendable {
    case idle
    case searching
    case loaded
    case saving
    case failed(String)
  }

  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.unsplashClient) private var unsplash
  @ObservationIgnored @Dependency(\.imageFetcher) private var imageFetcher
  @ObservationIgnored @Dependency(\.uuid) private var uuid

  public let regionID: MapRegion.ID

  /// The editable Unsplash query, seeded from the region name.
  public var query: String
  public private(set) var phase: Phase = .idle
  public private(set) var results: [UnsplashPhoto] = []

  public init(regionID: MapRegion.ID, regionName: String) {
    self.regionID = regionID
    self.query = regionName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Run the current query. No-op on a blank query; transport failure surfaces
  /// `.failed` (the sheet shows a retry state) rather than throwing.
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

  /// Commit a chosen Unsplash photo. Order matters: ping the ToS tracked-download
  /// endpoint first (best-effort), then download the bytes, process to tiers, and
  /// store — bytes-for-both so one render path serves Unsplash and Photos alike.
  /// Returns true on success so the sheet can dismiss.
  @discardableResult
  public func choose(_ photo: UnsplashPhoto) async -> Bool {
    phase = .saving
    await unsplash.registerDownload(for: photo)
    guard let url = URL(string: photo.regularURL), let data = await imageFetcher(url) else {
      phase = .failed("Couldn't download that photo. Check your connection and try again.")
      return false
    }
    return await store(
      data,
      sourceURL: photo.regularURL,
      photographerName: photo.photographerName.isEmpty ? nil : photo.photographerName,
      photographerUsername: photo.photographerUsername.isEmpty ? nil : photo.photographerUsername)
  }

  /// Commit a photo picked from the user's library (raw transferred bytes, no
  /// attribution). Returns true on success so the sheet can dismiss.
  @discardableResult
  public func chooseFromLibrary(_ data: Data) async -> Bool {
    phase = .saving
    return await store(data, sourceURL: nil, photographerName: nil, photographerUsername: nil)
  }

  /// Remove the region's photo.
  public func clear() async {
    try? await database.write { [regionID] db in
      try RegionImage.clear(forRegion: regionID, in: db)
    }
  }

  private func store(
    _ data: Data,
    sourceURL: String?,
    photographerName: String?,
    photographerUsername: String?
  ) async -> Bool {
    guard let processed = ImageProcessing.process(data) else {
      phase = .failed("That image couldn't be read. Try a different photo.")
      return false
    }
    let id = uuid()
    do {
      try await database.write { [regionID] db in
        try RegionImage.set(
          regionID: regionID,
          display: processed.display,
          thumbnail: processed.thumbnail,
          sourceURL: sourceURL,
          photographerName: photographerName,
          photographerUsername: photographerUsername,
          id: id,
          in: db)
      }
      return true
    } catch {
      phase = .failed("Couldn't save that photo. Try again.")
      return false
    }
  }
}
