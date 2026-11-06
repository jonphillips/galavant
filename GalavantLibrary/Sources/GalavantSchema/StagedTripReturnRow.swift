import ChatAccessKit
import Foundation
import GalavantAI

public struct StagedTripReturnRow: Identifiable, Equatable, Sendable {
  public enum Destination: Equatable, Sendable {
    case candidates(Trip, count: Int)
    case seed(Trip, placeCount: Int)
    case unknownTrip(UUID)
    case unreadable(String)
  }

  public enum DownloadState: Equatable, Sendable {
    case downloading
    case current
    case failed(String)
  }

  public enum Cached: Equatable, Sendable {
    case validated(StagedTripReturn.Validated)
    case failed(String)
  }

  public let url: URL
  public let stagedAt: Date
  public let destination: Destination
  public let downloadState: DownloadState
  public var id: URL { url }

  public static func rows(
    from snapshots: [ChatInboxSnapshot], trips: [Trip], cache: [URL: Cached]
  ) -> [Self] {
    let tripsByID = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
    return snapshots.compactMap { snapshot -> Self? in
      guard snapshot.url.pathExtension == "gvreturn", let staged = StagedHandoff(url: snapshot.url) else { return nil }
      let downloadState: DownloadState = snapshot.isCurrent
        ? (cache[snapshot.url] == nil ? .downloading : .current)
        : snapshot.downloadError.map(DownloadState.failed) ?? .downloading
      let destination: Destination
      if let tripID = UUID(uuidString: staged.slug) {
        if let trip = tripsByID[tripID] {
          switch cache[snapshot.url] {
          case let .validated(.candidates(_, candidates, _)): destination = .candidates(trip, count: candidates.filter { !$0.suggestedTitle.isEmpty }.count)
          case let .validated(.seed(_, seed)): destination = .seed(trip, placeCount: seed.places.count + seed.bases.count)
          case let .failed(error): destination = .unreadable(error)
          case nil: destination = .candidates(trip, count: 0)
          }
        } else {
          destination = .unknownTrip(tripID)
        }
      } else {
        destination = .unreadable("This return has an invalid trip ID.")
      }
      return Self(url: snapshot.url, stagedAt: staged.stagedAt, destination: destination, downloadState: downloadState)
    }.sorted { $0.stagedAt > $1.stagedAt }
  }
}
