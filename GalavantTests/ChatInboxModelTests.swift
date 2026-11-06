import ChatAccessKit
import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantAI
import GalavantSchema
import Observation
import SQLiteData
import Synchronization
import Testing

@testable import Galavant

@Suite(.serialized, .dependencies {
  try $0.bootstrapDatabase()
  $0.date = .constant(Date(timeIntervalSince1970: 1_000))
  $0.uuid = .incrementing
})
@MainActor
struct ChatInboxModelTests {
  @Dependency(\.defaultDatabase) private var database

  private enum ClaimFailure: Error { case failed }
  private struct State: Sendable {
    var session: HandoffSession?
    var savedAtClaim = false
    var attempts = 0
    var reads = 0
  }

  @Test(arguments: ["retry", "alreadyClaimed", "nothingRemaining"])
  func openSavesBeforeClaimAndHandlesFailures(scenario: String) async throws {
    let trip = try await database.write { db in try Trip.create(name: "Denmark", in: db) }
    let token = UUID()
    let text = "GV-HANDOFF: \(token)\n[{\"name\":\"Museum\"}]"
    if scenario == "nothingRemaining" {
      try await database.write { db in
        let candidate = TripCandidate(name: "Museum")
        let idea = try TripIdea.commit(candidate: candidate, into: trip.id, in: db)
        try TripIdea.where { $0.id.eq(idea.id) }.update { $0.status = #bind(TripIdeaStatus.declined) }.execute(db)
      }
    }
    let state = Mutex(State())
    let folder = ChatAccessFolder(containerURL: FileManager.default.temporaryDirectory, isDevelopment: true)
    let url = folder.inboxURL.appending(path: "20261105T120000Z-\(trip.id.uuidString).gvreturn")
    let snapshot = ChatInboxSnapshot(url: url, name: url.lastPathComponent, isCurrent: true)
    let (snapshots, continuation) = AsyncStream<[ChatInboxSnapshot]>.makeStream()
    let oldEnabled = UserDefaults.standard.object(forKey: ChatInboxModel.enabledKey)
    defer { UserDefaults.standard.set(oldEnabled, forKey: ChatInboxModel.enabledKey) }
    try await withDependencies {
      $0.handoffSessionStore.save = { session in state.withLock { $0.session = session } }
      $0.handoffSessionStore.session = { id in state.withLock { $0.session?.id == id ? $0.session : nil } }
      $0.chatInboxWatcher = { _ in
        ChatInboxObservation(snapshots: snapshots, stop: { continuation.finish() })
      }
      $0.chatAccessContainer = .init(resolveFolder: { folder }, resolveAndCreateInbox: { folder })
      $0.chatInboxFiles = .init(read: { _ in text }, claim: { _, _, _ in
        let attempt = state.withLock { state in
          state.savedAtClaim = state.session != nil
          state.attempts += 1
          return state.attempts
        }
        if scenario == "alreadyClaimed" { throw HandoffInboxError.alreadyClaimed }
        if scenario == "retry" && attempt == 1 { throw ClaimFailure.failed }
      }, maintain: { _, _, _ in })
    } operation: {
      let model = ChatInboxModel()
      model.setEnabled(true)
      await model.prepare()
      try await model.$trips.load()
      continuation.yield([snapshot])
      while model.rows.first?.downloadState != .current {
        await withCheckedContinuation { continuation in
          withObservationTracking { _ = model.rows } onChange: { continuation.resume() }
        }
      }
      let row = try #require(model.rows.first { $0.url == url && $0.downloadState == .current })
      let first = await model.open(row)
      #expect(state.withLock { $0.savedAtClaim })
      if scenario == "retry" {
        #expect(first == nil)
        #expect(model.rowErrors[url] != nil)
        #expect(model.rows.contains { $0.url == url })
        let second = await model.open(row)
        #expect(second != nil)
        let rows = try await database.read { db in try TripIdea.where { $0.tripID.eq(trip.id) }.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(model.rows.isEmpty)
      } else if scenario == "alreadyClaimed" {
        #expect(first == nil)
        #expect(model.rows.isEmpty)
        #expect(model.rowErrors[url] == nil)
      } else {
        #expect(first == nil)
        #expect(model.notice == "Every option is already on the trip.")
        #expect(model.message == nil)
        await model.copy(row)
        #expect(model.notice == nil)
      }
      model.setEnabled(false)
    }
  }

  @Test(arguments: ["retry", "discard", "alreadyClaimed"])
  func seedClaimsOnlyAfterCommit(scenario: String) async throws {
    let trip = try await database.write { db in try Trip.create(name: "Denmark", in: db) }
    let token = UUID()
    let text = "GV-HANDOFF: \(token)\nA morning at the museum.\nGV-SEED\n{\"places\":[{\"name\":\"Museum\"}]}"
    let state = Mutex(State())
    let folder = ChatAccessFolder(containerURL: FileManager.default.temporaryDirectory, isDevelopment: true)
    let url = folder.inboxURL.appending(path: "20261105T120000Z-\(trip.id.uuidString).gvreturn")
    let snapshot = ChatInboxSnapshot(url: url, name: url.lastPathComponent, isCurrent: true)
    let (snapshots, continuation) = AsyncStream<[ChatInboxSnapshot]>.makeStream()
    let oldEnabled = UserDefaults.standard.object(forKey: ChatInboxModel.enabledKey)
    defer { UserDefaults.standard.set(oldEnabled, forKey: ChatInboxModel.enabledKey) }
    try await withDependencies {
      $0.handoffSessionStore.save = { session in state.withLock { $0.session = session } }
      $0.handoffSessionStore.session = { id in state.withLock { $0.session?.id == id ? $0.session : nil } }
      $0.chatInboxWatcher = { _ in
        ChatInboxObservation(snapshots: snapshots, stop: { continuation.finish() })
      }
      $0.chatAccessContainer = .init(resolveFolder: { folder }, resolveAndCreateInbox: { folder })
      $0.chatInboxFiles = .init(read: { _ in
        state.withLock { $0.reads += 1 }
        return text
      }, claim: { _, _, _ in
        let attempt = state.withLock { state in
          state.savedAtClaim = state.session?.status == .imported
          state.attempts += 1
          return state.attempts
        }
        if scenario == "alreadyClaimed" { throw HandoffInboxError.alreadyClaimed }
        if attempt == 1 { throw ClaimFailure.failed }
      }, maintain: { _, _, _ in })
    } operation: {
      let model = ChatInboxModel()
      let router = AppRouter()
      router.selection = .evaluate
      model.setEnabled(true)
      defer { model.setEnabled(false) }
      await model.prepare()
      try await model.$trips.load()
      continuation.yield([snapshot])
      while model.rows.first?.downloadState != .current {
        await withCheckedContinuation { continuation in
          withObservationTracking { _ = model.rows } onChange: { continuation.resume() }
        }
      }
      let row = try #require(model.rows.first)
      #expect(row.destination == .seed(trip, placeCount: 1))
      #expect(model.readyCount == 1)

      await model.openSeed(row, router: router)
      #expect(router.selection == .trips)
      #expect(router.openTrip?.id == trip.id)
      #expect(state.withLock { $0.reads } == 2)
      let planning = router.planningModel(for: trip)
      #expect(try seedPresentation(in: planning).seedReview?.plan?.seed.narrative == "A morning at the museum.")
      planning.destination = nil
      #expect(state.withLock { $0.attempts } == 0)
      #expect(state.withLock { $0.session } == nil)
      #expect(model.readyCount == 1)

      await model.openSeed(row, router: router)
      let presentation = try seedPresentation(in: planning)
      let review = try #require(presentation.seedReview)
      #expect(presentation.session.id == token)
      #expect(presentation.session.taskType == RecommendationHandoffTask.seedTrip)
      try #require(review.commit(from: presentation.session))
      await waitForSeedClaim(model, url: url)
      #expect(state.withLock { $0.savedAtClaim })
      if scenario == "alreadyClaimed" {
        #expect(model.rowErrors[url] == nil)
      } else {
        #expect(model.rowErrors[url] != nil)
        #expect(model.readyCount == 1)
        if scenario == "retry" {
          planning.destination = nil
          await model.openSeed(row, router: router)
          let retry = try seedPresentation(in: planning)
          let retryReview = try #require(retry.seedReview)
          #expect(retryReview.plan?.places.first?.include == false)
          try #require(retryReview.commit(from: retry.session))
          await waitForSeedClaim(model, url: url)
        } else {
          await model.discard(row)
        }
        #expect(state.withLock { $0.attempts } == 2)
      }
      #expect(model.rows.isEmpty)
      #expect(model.readyCount == 0)
      #expect(model.rowErrors[url] == nil)
      try await database.read { db in
        let rowCount = try TripIdea.where { $0.tripID.eq(trip.id) }.fetchCount(db)
        let documentCount = try TripDocument.where { $0.tripID.eq(trip.id) }.fetchCount(db)
        #expect(rowCount == 1)
        #expect(documentCount == 1)
      }
    }
  }

  private func seedPresentation(in model: TripPlanningModel) throws -> RecommendationHandoffPresentation {
    try #require(model.destination?[case: \.recommendationHandoff])
  }

  private func waitForSeedClaim(_ model: ChatInboxModel, url: URL) async {
    while !model.rows.isEmpty && model.rowErrors[url] == nil {
      await withCheckedContinuation { continuation in
        withObservationTracking {
          _ = model.rows
          _ = model.rowErrors
        } onChange: { continuation.resume() }
      }
    }
  }
}
