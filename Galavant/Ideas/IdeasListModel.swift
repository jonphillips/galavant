import CasePaths
import CloudKit
import Dependencies
import Foundation
import GalavantSchema
import MapKit
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
  @ObservationIgnored @FetchAll(MapRegion.order(by: \.name)) var regions
  @ObservationIgnored @Shared(.appStorage("currentPlannerID")) var currentPlannerIDString = ""
  var destination: Destination?
  var sharedRecord: SharedRecord?

  // Pool filters (the "Virginia case" scoping).
  var selectedRegionID: MapRegion.ID?
  var selectedKinds: Set<IdeaKind> = []
  var includeVisited = true

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

  var selectedRegion: MapRegion? {
    guard let id = selectedRegionID else { return nil }
    return regions.first { $0.id == id }
  }

  var filteredIdeas: [Idea] {
    poolFiltered(
      ideas,
      region: selectedRegion,
      kinds: selectedKinds,
      includeVisited: includeVisited
    )
  }

  var isFiltering: Bool {
    selectedRegionID != nil || !selectedKinds.isEmpty || !includeVisited
  }

  /// Human-readable summary of the active filters, for the reminder bar.
  var filterSummary: String {
    var parts: [String] = []
    if let region = selectedRegion { parts.append(region.name) }
    if !selectedKinds.isEmpty {
      parts.append(selectedKinds.map(\.label).sorted().joined(separator: ", "))
    }
    if !includeVisited { parts.append("hiding visited") }
    return parts.joined(separator: " · ")
  }

  func toggleKind(_ kind: IdeaKind) {
    if selectedKinds.contains(kind) {
      selectedKinds.remove(kind)
    } else {
      selectedKinds.insert(kind)
    }
  }

  func clearFilters() {
    selectedRegionID = nil
    selectedKinds = []
    includeVisited = true
  }

  func saveRegion(named name: String, center: CLLocationCoordinate2D, span: MKCoordinateSpan) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    withErrorReporting {
      try database.write { db in
        let partyID = try TravelParty.ensureDefault(in: db).id
        try MapRegion.insert {
          MapRegion.Draft(
            id: UUID(),
            name: trimmed,
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            latitudeDelta: span.latitudeDelta,
            longitudeDelta: span.longitudeDelta,
            travelPartyID: partyID
          )
        }
        .execute(db)
      }
    }
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
