import CasePaths
import CloudKit
import Dependencies
import Foundation
import GalavantSchema
import os
import SQLiteData
import Sharing

@MainActor
@Observable
final class IdeasListModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored @Dependency(\.defaultSyncEngine) var syncEngine
  @ObservationIgnored @FetchAll(Idea.order(by: \.name)) var ideas
  @ObservationIgnored @FetchAll(Planner.all) var planners
  @ObservationIgnored @FetchAll(IdeaInterest.all) var interests
  @ObservationIgnored @Shared(.appStorage("currentPlannerID")) var currentPlannerIDString = ""
  var destination: Destination?
  var sharedRecord: SharedRecord?

  init() {
    // Test hook: simulate a device that doesn't yet know which planner it is
    // (e.g. a freshly synced second device) without wiping the shared data.
    if CommandLine.arguments.contains("--reset-identity") {
      $currentPlannerIDString.withLock { $0 = "" }
    }
  }

  @CasePathable
  enum Destination {
    case form(Idea.Draft)
    case identity
  }

  var currentPlanner: Planner? {
    guard let id = UUID(uuidString: currentPlannerIDString) else { return nil }
    return planners.first { $0.id == id }
  }

  func task() async {
    if currentPlanner == nil {
      destination = .identity
    }
  }

  /// Bind this device to an existing synced planner (ADR-0008) — the second-device
  /// path. Only the device-local `currentPlannerID` changes; no new row is created.
  func selectPlanner(_ planner: Planner) {
    $currentPlannerIDString.withLock { $0 = planner.id.uuidString }
    destination = nil
  }

  /// Create a brand-new planner and bind to it — the genuinely-first-run path.
  func createPlanner(named name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    withErrorReporting {
      let planner = try database.write { db in
        try Planner.create(displayName: trimmed, in: db)
      }
      $currentPlannerIDString.withLock { $0 = planner.id.uuidString }
    }
    destination = nil
  }

  func interests(for idea: Idea) -> [(planner: Planner, level: Interest)] {
    interests
      .filter { $0.ideaID == idea.id && $0.level != nil }
      .compactMap { ideaInterest in
        guard
          let planner = planners.first(where: { $0.id == ideaInterest.plannerID }),
          let level = ideaInterest.level
        else { return nil }
        return (planner, level)
      }
      .sorted { $0.planner.displayName < $1.planner.displayName }
  }

  func myInterest(for idea: Idea) -> Interest? {
    guard let me = currentPlanner else { return nil }
    return interests.first { $0.ideaID == idea.id && $0.plannerID == me.id }?.level
  }

  func setMyInterest(_ level: Interest?, for idea: Idea) {
    guard let me = currentPlanner else { return }
    withErrorReporting {
      try database.write { db in
        try IdeaInterest.set(level: level, ideaID: idea.id, plannerID: me.id, in: db)
      }
    }
  }

  func addIdeaButtonTapped() {
    destination = .form(Idea.Draft())
  }

  func ideaTapped(_ idea: Idea) {
    destination = .form(Idea.Draft(idea))
  }

  func deleteIdeas(at offsets: IndexSet) {
    let ids = offsets.map { ideas[$0].id }
    withErrorReporting {
      try database.write { db in
        try Idea.where { $0.id.in(ids) }.delete().execute(db)
      }
    }
  }

  func shareTravelPartyButtonTapped() async {
    await withErrorReporting {
      let travelParty = try await database.write { db in
        try TravelParty.ensureDefault(in: db)
      }
      sharedRecord = try await syncEngine.share(record: travelParty) {
        $0[CKShare.SystemFieldKey.title] = "Galavant Travel Party"
      }
      #if DEBUG
        if let url = sharedRecord?.share.url {
          Logger(subsystem: "com.jonphillips.galavant", category: "Sharing")
            .warning("TRAVEL PARTY SHARE URL: \(url.absoluteString, privacy: .public)")
        }
      #endif
    }
  }
}
