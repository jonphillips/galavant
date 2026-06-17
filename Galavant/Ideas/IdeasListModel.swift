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
  @ObservationIgnored @Dependency(\.recentTripStore) var recentTripStore
  @ObservationIgnored @FetchAll(Idea.order(by: \.name)) var ideas
  @ObservationIgnored @FetchAll(Planner.all) var planners
  @ObservationIgnored @FetchAll(IdeaInterest.all) var interests
  @ObservationIgnored @FetchAll(MapRegion.order(by: \.name)) var regions
  @ObservationIgnored @FetchAll(Tag.order(by: \.name)) var tags
  @ObservationIgnored @FetchAll(IdeaTag.all) var ideaTags
  @ObservationIgnored @FetchAll(Trip.all) var trips
  @ObservationIgnored @FetchAll(TripIdea.all) var tripIdeas
  @ObservationIgnored @FetchAll(TripRegion.all) var tripRegions
  @ObservationIgnored @Shared(.appStorage("currentPlannerID")) var currentPlannerIDString = ""
  var destination: Destination?
  var sharedRecord: SharedRecord?

  // Pool filters (the "Virginia case" scoping).
  var selectedRegionID: MapRegion.ID?
  var selectedKinds: Set<IdeaKind> = []
  var selectedTagIDs: Set<Tag.ID> = []
  var includeVisited = true
  /// Worklist controls over the his/hers "match" projection (BACKLOG "match
  /// signal"): hide all but matches, and float matches to the top.
  var showMatchesOnly = false
  var sortMode: IdeaSort = .alphabetical

  enum IdeaSort: String, CaseIterable {
    case alphabetical, matchesFirst
    var label: String {
      switch self {
      case .alphabetical: "A–Z"
      case .matchesFirst: "Matches first"
      }
    }
  }

  /// The active-trip capsule (nil = "All", the eternal pool). When set, the pool
  /// is scoped to that trip's regions and rows become a pull/rate surface for it
  /// — the Ideas screen's launchpad half (BACKLOG "Ideas list trip-awareness").
  var activeTripID: Trip.ID?

  var ideaTagIDs: [Idea.ID: Set<Tag.ID>] {
    Dictionary(grouping: ideaTags, by: \.ideaID).mapValues { Set($0.map(\.tagID)) }
  }

  var sortedTags: [Tag] {
    tags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  var sortedRegions: [MapRegion] {
    regions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

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

  // MARK: - Active-trip capsules (launchpad)

  /// The in-play trips to show as capsules, lifecycle-derived (not filter MRU).
  var capsules: [Trip] { Trip.activeCapsules(trips) }

  var activeTrip: Trip? {
    guard let id = activeTripID else { return nil }
    return trips.first { $0.id == id }
  }

  /// The regions scoping the pool: the active trip's saved lens when a capsule is
  /// selected, otherwise the manual region filter. A trip defines its own
  /// geography, so its capsule replaces the single-region menu.
  private var scopeRegions: [MapRegion] {
    if let trip = activeTrip {
      let ids = Set(tripRegions.filter { $0.tripID == trip.id }.map(\.regionID))
      return regions.filter { ids.contains($0.id) }
    }
    return selectedRegion.map { [$0] } ?? []
  }

  /// Select an active-trip capsule, or `nil` for "All" (the eternal pool).
  /// Selecting an actual trip records it as the recent trip so a share-extension
  /// capture defaults onto it; selecting "All" doesn't erase that memory.
  func selectCapsule(_ tripID: Trip.ID?) {
    activeTripID = tripID
    if let tripID { recentTripStore.record(tripID) }
  }

  var filteredIdeas: [Idea] {
    let pooled = poolFiltered(
      ideas,
      regions: scopeRegions,
      kinds: selectedKinds,
      includeVisited: includeVisited,
      tagIDs: selectedTagIDs,
      ideaTagIDs: ideaTagIDs
    )
    let standings = standingByIdea
    let matched = showMatchesOnly ? pooled.filter { standings[$0.id] == .match } : pooled
    switch sortMode {
    case .alphabetical:
      return matched  // `ideas` is already fetched name-ordered
    case .matchesFirst:
      return matched.sorted {
        ((standings[$0.id] ?? .neutral).sortKey, $0.name.lowercased())
          < ((standings[$1.id] ?? .neutral).sortKey, $1.name.lowercased())
      }
    }
  }

  // MARK: - His/hers ratings + match projection

  /// Every travel-party planner with their level for an idea (nil = pending),
  /// name-ordered — but only when *someone* has rated, so a fully-unrated idea
  /// shows no his/hers row (keeps the firehose quiet while still distinguishing
  /// Decide Later from pending).
  func ratingRow(for idea: Idea) -> [(planner: Planner, level: Interest?)] {
    let byPlanner = Dictionary(
      interests.filter { $0.ideaID == idea.id }.map { ($0.plannerID, $0.level) },
      uniquingKeysWith: { first, _ in first }
    )
    let sorted = planners.sorted { $0.displayName < $1.displayName }
    guard sorted.contains(where: { (byPlanner[$0.id] ?? nil) != nil }) else { return [] }
    return sorted.map { (planner: $0, level: byPlanner[$0.id] ?? nil) }
  }

  private var standingByIdea: [Idea.ID: MatchStanding] {
    Dictionary(grouping: interests.filter { $0.level != nil }, by: \.ideaID)
      .mapValues { Interest.standing($0.map(\.level)) }
  }

  func isMatch(_ idea: Idea) -> Bool { standingByIdea[idea.id] == .match }

  // MARK: - Trip-association badges (cell signal)

  private var tripsByID: [Trip.ID: Trip] {
    Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
  private var entriesByIdea: [Idea.ID: [TripIdea]] {
    Dictionary(grouping: tripIdeas, by: \.ideaID)
  }

  /// The "All"-view badge for an idea: its most-actionable trip association
  /// (scheduled > upcoming > someday > visited), or nil for a free idea.
  func tripBadge(for idea: Idea) -> IdeaTripBadge? {
    IdeaTripBadge.badge(
      forIdea: idea,
      entries: entriesByIdea[idea.id] ?? [],
      tripsByID: tripsByID
    )
  }

  /// This idea's status on the active trip — drives the pull toggles when a
  /// capsule is selected. Nil when no capsule is active or it isn't pulled.
  func activeTripStatus(for idea: Idea) -> TripIdeaStatus? {
    guard let tripID = activeTripID else { return nil }
    return tripIdeas.first { $0.tripID == tripID && $0.ideaID == idea.id }?.status
  }

  var isFiltering: Bool {
    selectedRegionID != nil || !selectedKinds.isEmpty || !selectedTagIDs.isEmpty
      || !includeVisited || showMatchesOnly
  }

  /// Human-readable summary of the active filters, for the reminder bar.
  var filterSummary: String {
    var parts: [String] = []
    if let region = selectedRegion { parts.append(region.name) }
    if !selectedKinds.isEmpty {
      parts.append(selectedKinds.map(\.label).sorted().joined(separator: ", "))
    }
    if !selectedTagIDs.isEmpty {
      let names = tags.filter { selectedTagIDs.contains($0.id) }.map(\.name).sorted()
      parts.append(names.joined(separator: ", "))
    }
    if !includeVisited { parts.append("hiding visited") }
    if showMatchesOnly { parts.append("matches only") }
    return parts.joined(separator: " · ")
  }

  func toggleKind(_ kind: IdeaKind) {
    if selectedKinds.contains(kind) {
      selectedKinds.remove(kind)
    } else {
      selectedKinds.insert(kind)
    }
  }

  func toggleTag(_ id: Tag.ID) {
    if selectedTagIDs.contains(id) {
      selectedTagIDs.remove(id)
    } else {
      selectedTagIDs.insert(id)
    }
  }

  func clearFilters() {
    selectedRegionID = nil
    selectedKinds = []
    selectedTagIDs = []
    includeVisited = true
    showMatchesOnly = false
  }

  func deleteRegions(at offsets: IndexSet) {
    let ids = offsets.map { regions[$0].id }
    withErrorReporting {
      try database.write { db in
        try MapRegion.where { $0.id.in(ids) }.delete().execute(db)
      }
    }
    if let selected = selectedRegionID, ids.contains(selected) {
      selectedRegionID = nil
    }
  }

  func renameRegion(_ region: MapRegion, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    withErrorReporting {
      try database.write { db in
        try MapRegion.find(region.id).update { $0.name = trimmed }.execute(db)
      }
    }
  }

  func deleteTags(at offsets: IndexSet) {
    let ids = offsets.map { sortedTags[$0].id }
    withErrorReporting {
      try database.write { db in
        try Tag.where { $0.id.in(ids) }.delete().execute(db)
        // tagID is a loose UUID (not a SQL FK), so clean up join rows by hand.
        try IdeaTag.where { $0.tagID.in(ids) }.delete().execute(db)
      }
    }
    selectedTagIDs.subtract(ids)
  }

  func renameTag(_ tag: Tag, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    withErrorReporting {
      try database.write { db in
        try Tag.find(tag.id).update { $0.name = trimmed }.execute(db)
      }
    }
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

  /// Re-read the pool after a write from another process (the share extension),
  /// which `@FetchAll`'s in-process observation can't see. Driven by
  /// `DatabaseChange` notifications and foreground transitions (IdeasScreen). The
  /// capture only inserts an `Idea`, so reloading the pool suffices.
  func reloadAfterExternalWrite() async {
    await withErrorReporting {
      try await $ideas.load()
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

  // MARK: - Pull onto the active trip

  /// Toggle an idea's "considering" state on the active trip (the launchpad's
  /// thought-bubble): pull it if it's off the trip, demote a shortlisted one, or
  /// remove an already-considering one. Mirrors `TripPlanningModel.tapConsidering`
  /// over the same tested `TripIdea` ops; a no-op when no capsule is active.
  func tapConsideringOnActiveTrip(_ idea: Idea) {
    guard let tripID = activeTripID else { return }
    let ideaID = idea.id
    withErrorReporting {
      try database.write { db in
        switch activeTripStatus(for: idea) {
        case nil: try TripIdea.pull(ideaID: ideaID, into: tripID, in: db)
        case .considering: try TripIdea.remove(ideaID: ideaID, from: tripID, in: db)
        case .shortlisted: try TripIdea.setStatus(.considering, ideaID: ideaID, tripID: tripID, in: db)
        case .scheduled, .done, .skipped: break  // manage scheduled stops from the trip
        }
      }
    }
  }

  /// Toggle an idea's shortlist state on the active trip (the launchpad's star):
  /// pull straight to the shortlist, promote a considering one, or remove an
  /// already-shortlisted one. Mirrors `TripPlanningModel.tapShortlist`.
  func tapShortlistOnActiveTrip(_ idea: Idea) {
    guard let tripID = activeTripID else { return }
    let ideaID = idea.id
    withErrorReporting {
      try database.write { db in
        switch activeTripStatus(for: idea) {
        case nil:
          try TripIdea.pull(ideaID: ideaID, into: tripID, in: db)
          try TripIdea.setStatus(.shortlisted, ideaID: ideaID, tripID: tripID, in: db)
        case .considering: try TripIdea.setStatus(.shortlisted, ideaID: ideaID, tripID: tripID, in: db)
        case .shortlisted: try TripIdea.remove(ideaID: ideaID, from: tripID, in: db)
        case .scheduled, .done, .skipped: break
        }
      }
    }
  }

  func addIdeaButtonTapped() {
    destination = .form(Idea.Draft())
  }

  func ideaTapped(_ idea: Idea) {
    destination = .form(Idea.Draft(idea))
  }

  func deleteIdeas(_ displayed: [Idea], at offsets: IndexSet) {
    let ids = offsets.map { displayed[$0].id }
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
