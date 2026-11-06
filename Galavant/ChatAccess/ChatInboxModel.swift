import ChatAccessKit
import Dependencies
import Foundation
import GalavantAI
import GalavantSchema
import Observation
import SQLiteData
import UIKit

@MainActor
@Observable
final class ChatInboxModel {
  static let enabledKey = "chatAccessEnabled"
  static let kind = ChatInboxItemKind(fileExtension: "gvreturn", expiresUnclaimed: true, datesProcessedByClaim: true)

  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.handoffSessionStore) private var sessions
  @ObservationIgnored @Dependency(\.date.now) private var now
  @ObservationIgnored @Dependency(\.uuid) private var uuid
  @ObservationIgnored @FetchAll(Trip.all) private var trips
  @ObservationIgnored @Dependency(\.chatInboxFiles) private var files
  @ObservationIgnored @Dependency(\.chatAccessContainer) private var container
  @ObservationIgnored private var watcher: ChatInboxWatcher?
  @ObservationIgnored private var watcherTask: Task<Void, Never>?
  private var snapshots: [ChatInboxSnapshot] = []
  private var cache: [URL: StagedTripReturnRow.Cached] = [:]
  @ObservationIgnored private var reading: Set<URL> = []
  @ObservationIgnored private var claimed: Set<URL> = []
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var folder: ChatAccessFolder?
  private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
  private(set) var message: String?
  private(set) var rowErrors: [URL: String] = [:]
  private(set) var working: Set<URL> = []


  isolated deinit {
    watcher?.stop()
    watcherTask?.cancel()
  }

  var rows: [StagedTripReturnRow] {
    guard enabled else { return [] }
    return StagedTripReturnRow.rows(from: snapshots, trips: trips, cache: cache)
  }

  var readyCount: Int {
    rows.filter { row in
      guard row.downloadState == .current, case .candidates = row.destination else { return false }
      return true
    }.count
  }

  func setEnabled(_ value: Bool) {
    enabled = value
    UserDefaults.standard.set(value, forKey: Self.enabledKey)
    if value { Task { await prepare() } } else { stop() }
  }

  func prepare() async {
    guard enabled else { return }
    let currentGeneration = generation
    do {
      let folder = try await container.resolveAndCreateInbox()
      guard enabled, generation == currentGeneration else { return }
      self.folder = folder
      if watcher == nil {
        let watcher = ChatInboxWatcher(folder: folder)
        self.watcher = watcher
        watcherTask = Task { [weak self] in
          for await snapshots in watcher.snapshots { self?.receive(snapshots) }
        }
        watcher.start()
      }
      try await files.maintain(folder, [Self.kind], now)
      message = nil
    } catch {
      guard enabled, generation == currentGeneration else { return }
      message = error.localizedDescription
    }
  }

  private func stop() {
    generation += 1
    watcher?.stop()
    watcher = nil
    watcherTask?.cancel()
    watcherTask = nil
    folder = nil
    snapshots = []
    cache = [:]
    reading = []
    claimed = []
    message = nil
  }

  private func receive(_ snapshots: [ChatInboxSnapshot]) {
    claimed.formIntersection(Set(snapshots.map(\.url)))
    self.snapshots = snapshots.filter { !claimed.contains($0.url) }
    for snapshot in self.snapshots where snapshot.isCurrent && snapshot.url.pathExtension == Self.kind.fileExtension {
      guard cache[snapshot.url] == nil, reading.insert(snapshot.url).inserted else { continue }
      let generation = generation
      Task {
        defer { reading.remove(snapshot.url) }
        do {
          let text = try await files.read(snapshot.url)
          guard enabled, self.generation == generation else { return }
          do { cache[snapshot.url] = .validated(try StagedTripReturn.validate(text)) }
          catch { cache[snapshot.url] = .failed(error.localizedDescription) }
        } catch {
          guard enabled, self.generation == generation else { return }
          cache[snapshot.url] = .failed(error.localizedDescription)
        }
      }
    }
  }

  func open(_ row: StagedTripReturnRow) async -> EvaluateQueueEntry? {
    guard case let .candidates(trip, _) = row.destination,
      case let .validated(.candidates(token, candidates, note)) = cache[row.url],
      let folder, working.isEmpty, working.insert(row.url).inserted else { return nil }
    defer { working.remove(row.url) }
    do {
      let existing = token.flatMap { sessions.session($0) }
      let session = RecommendationSetImport.session(
        token: token, existing: existing, tripID: trip.id, now: now, newID: uuid()
      )
      let date = now
      let result = try await database.write { db in
        try RecommendationSetImport.apply(candidates: candidates, note: note, into: trip.id, session: session, now: date, in: db)
      }
      try sessions.save(result.session)
      try await files.claim(folder, row.url, Self.kind)
      forget(row.url)
      guard result.remainingCount > 0 else {
        message = "Every option is already on the trip."
        return nil
      }
      return EvaluateQueueEntry(sessionID: result.session.id, tripID: trip.id, tripName: trip.name,
        remainingCount: result.remainingCount, createdAt: result.session.createdAt)
    } catch HandoffInboxError.alreadyClaimed {
      forget(row.url)
    } catch {
      rowErrors[row.url] = error.localizedDescription
    }
    return nil
  }

  func discard(_ row: StagedTripReturnRow) async {
    guard let folder, working.insert(row.url).inserted else { return }
    defer { working.remove(row.url) }
    do {
      try await files.claim(folder, row.url, Self.kind)
      forget(row.url)
    } catch HandoffInboxError.alreadyClaimed {
      forget(row.url)
    } catch {
      rowErrors[row.url] = error.localizedDescription
    }
  }

  func copy(_ row: StagedTripReturnRow) async {
    do { UIPasteboard.general.string = try await files.read(row.url) }
    catch { rowErrors[row.url] = error.localizedDescription }
  }

  private func forget(_ url: URL) {
    claimed.insert(url)
    snapshots.removeAll { $0.url == url }
    cache[url] = nil
    rowErrors[url] = nil
  }
}

private enum ChatAccessContainerKey: DependencyKey {
  static var liveValue: ChatAccessContainerClient {
    #if DEBUG
    let isDevelopment = true
    #else
    let isDevelopment = false
    #endif
    return .live(containerIdentifier: "iCloud.com.jonphillips.galavant", isDevelopment: isDevelopment, appName: "Galavant")
  }
}

private enum ChatInboxFilesKey: DependencyKey {
  static var liveValue: ChatInboxFileClient { .live }
}

extension DependencyValues {
  var chatAccessContainer: ChatAccessContainerClient {
    get { self[ChatAccessContainerKey.self] }
    set { self[ChatAccessContainerKey.self] = newValue }
  }

  var chatInboxFiles: ChatInboxFileClient {
    get { self[ChatInboxFilesKey.self] }
    set { self[ChatInboxFilesKey.self] = newValue }
  }
}
