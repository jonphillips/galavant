import CasePaths
import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// Owns one trip's planning surface (ADR-0004): the shortlist + considering
/// pile of pulled ideas, and the filtered pool you pull *from*. Persistence
/// delegates to the tested `TripIdea` operations; pool scoping reuses the pure
/// `poolFiltered`. The view stays presentation.
@MainActor
@Observable
final class TripPlanningModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored @Dependency(\.recentTripStore) var recentTripStore
  @ObservationIgnored @Dependency(\.directionsClient) var directionsClient
  @ObservationIgnored @FetchAll(Trip.all) var trips
  @ObservationIgnored @FetchAll(Idea.order(by: \.name)) var ideas
  @ObservationIgnored @FetchAll(TripIdea.all) var allTripIdeas
  @ObservationIgnored @FetchAll(TripRegion.all) var allTripRegions
  @ObservationIgnored @FetchAll(MapRegion.order(by: \.name)) var regions
  @ObservationIgnored @FetchAll(Tag.order(by: \.name)) var tags
  @ObservationIgnored @FetchAll(IdeaTag.all) var ideaTags
  @ObservationIgnored @FetchAll(Planner.all) var planners
  @ObservationIgnored @FetchAll(IdeaInterest.all) var interestRows

  let tripID: Trip.ID
  var destination: Destination?

  /// The idea drilled into on the in-panel detail push (nil = the list root). A
  /// push within the panel, not a sheet, so it never covers the map; driven by ID
  /// so it resolves live and stays out of `Hashable`.
  var detailIdeaID: Idea.ID?

  // Canvas state (M3d): the map is the trip's home. `canvasSelectedDay` is the
  // day lens (nil = the whole trip, all days color-coded); `canvasSelectedStopID`
  // is the one selection the map pins and the timeline rows both project.
  var canvasSelectedDay: Int?
  var canvasSelectedStopID: TripIdea.ID?

  // ETA cache (docs/trip-canvas.md): walking travel times between consecutive
  // located stops. Populated on appear and when the itinerary changes.
  var travelTimes: [LegKey: TravelTime] = [:]
  private var isFetchingETAs = false
  private var pendingETAFetch = false
  // The two surfaces the bottom sheet hosts (the segment moved into the sheet).
  var sheetTab: SheetTab = .itinerary
  private var didPickInitialTab = false

  // Pool lens (reused from the Ideas screen, M2c), seeded from the trip's regions.
  var selectedRegionIDs: Set<MapRegion.ID> = []
  private var didSeedLens = false
  var selectedKinds: Set<IdeaKind> = []
  var selectedTagIDs: Set<Tag.ID> = []
  var includeVisited = true

  /// The two surfaces inside the bottom sheet over the map canvas.
  enum SheetTab: String, CaseIterable, Identifiable {
    case itinerary, ideas
    var id: Self { self }
    var label: String {
      switch self {
      case .itinerary: "Itinerary"
      case .ideas: "Ideas"
      }
    }
  }

  @CasePathable
  enum Destination {
    case edit(Trip.Draft)
    case addIdeas
    case scheduleStop
  }

  init(tripID: Trip.ID) {
    self.tripID = tripID
    // Opening a trip to plan it is the strongest "this is the trip I'm working on"
    // signal — record it so a share-extension capture defaults onto it.
    recentTripStore.record(tripID)
  }

  // MARK: - Derived state

  var trip: Trip? { trips.first { $0.id == tripID } }

  private var entries: [TripIdea] { allTripIdeas.filter { $0.tripID == tripID } }
  private var ideaByID: [Idea.ID: Idea] {
    Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// This trip's resolved planning read-model — the joins, projections, and
  /// canvas geometry live in the tested functional core (`TripPlan`), not here.
  /// Views read `model.plan.shortlist`, `model.plan.itinerary`, etc.; the model
  /// keeps only UI state and the db-write actions.
  var plan: TripPlan {
    TripPlan(entries: entries, ideasByID: ideaByID, lengthInDays: trip?.lengthInDays ?? 1)
  }

  // MARK: - Canvas mode (the map is the trip's home, M3d)

  /// The map regions this trip is scoped to — the camera's fallback frame when no
  /// stops have coordinates yet.
  var tripRegions: [MapRegion] { regions.filter { tripRegionIDs.contains($0.id) } }

  /// On first appear, land on Ideas rather than Itinerary when nothing is
  /// scheduled yet, so an empty map isn't a dead end. Runs once.
  func pickInitialSheetTabIfNeeded() {
    guard !didPickInitialTab else { return }
    didPickInitialTab = true
    sheetTab = plan.hasScheduledStops ? .itinerary : .ideas
  }

  /// Focus a stop from the map or the timeline — the single shared selection both
  /// surfaces project. Brings the Itinerary tab forward so the row is visible.
  func selectStop(_ id: TripIdea.ID?) {
    canvasSelectedStopID = id
    if id != nil { sheetTab = .itinerary }
  }

  // MARK: - Add mode (the pool, scoped by the lens)

  var ideaTagIDs: [Idea.ID: Set<Tag.ID>] {
    Dictionary(grouping: ideaTags, by: \.ideaID).mapValues { Set($0.map(\.tagID)) }
  }
  var selectedRegions: [MapRegion] { regions.filter { selectedRegionIDs.contains($0.id) } }

  /// The regions currently associated with this trip (the saved lens).
  var tripRegionIDs: Set<MapRegion.ID> {
    Set(allTripRegions.filter { $0.tripID == tripID }.map(\.regionID))
  }

  /// Seed the Add lens from the trip's saved regions, once on first appear. The
  /// user can adjust it per visit thereafter; editing the trip's regions
  /// re-seeds it (see `reseedLens`).
  func seedLensIfNeeded() {
    guard !didSeedLens else { return }
    didSeedLens = true
    selectedRegionIDs = tripRegionIDs
  }

  /// Re-seed the lens after the trip's regions change (e.g. the edit sheet, or
  /// a sync update) so the Add pool reflects the new set.
  func reseedLens() {
    selectedRegionIDs = tripRegionIDs
  }

  var filteredPool: [Idea] {
    poolFiltered(
      ideas,
      regions: selectedRegions,
      kinds: selectedKinds,
      includeVisited: includeVisited,
      tagIDs: selectedTagIDs,
      ideaTagIDs: ideaTagIDs
    )
  }

  private var statusByIdea: [Idea.ID: TripIdeaStatus] {
    Dictionary(entries.map { ($0.ideaID, $0.status) }, uniquingKeysWith: { first, _ in first })
  }

  /// This idea's status on the trip, or nil if it hasn't been pulled.
  func status(for idea: Idea) -> TripIdeaStatus? { statusByIdea[idea.id] }

  var sortedRegions: [MapRegion] {
    regions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
  var sortedTags: [Tag] {
    tags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
  var isFiltering: Bool {
    !selectedRegionIDs.isEmpty || !selectedKinds.isEmpty || !selectedTagIDs.isEmpty || !includeVisited
  }

  func toggleRegion(_ id: MapRegion.ID) {
    if selectedRegionIDs.contains(id) { selectedRegionIDs.remove(id) } else { selectedRegionIDs.insert(id) }
  }

  func toggleKind(_ kind: IdeaKind) {
    if selectedKinds.contains(kind) { selectedKinds.remove(kind) } else { selectedKinds.insert(kind) }
  }
  func toggleTag(_ id: Tag.ID) {
    if selectedTagIDs.contains(id) { selectedTagIDs.remove(id) } else { selectedTagIDs.insert(id) }
  }
  func clearFilters() {
    selectedRegionIDs = []
    selectedKinds = []
    selectedTagIDs = []
    includeVisited = true
  }

  // MARK: - ETA fetch

  /// Fetch walking ETAs for any uncached legs in the current itinerary.
  /// Runs sequentially (MKDirections allows only one in-flight request); if
  /// called while a fetch is already running, enqueues one re-run for after.
  func fetchMissingETAs() async {
    if isFetchingETAs {
      pendingETAFetch = true
      return
    }
    isFetchingETAs = true
    defer {
      isFetchingETAs = false
      if pendingETAFetch {
        pendingETAFetch = false
        Task { await fetchMissingETAs() }
      }
    }
    for leg in plan.allLegs where travelTimes[leg] == nil {
      guard !Task.isCancelled else { break }
      if let tt = try? await directionsClient.calculateETA(leg) {
        travelTimes[leg] = tt
      }
    }
  }

  // MARK: - Actions

  func editButtonTapped() {
    guard let trip else { return }
    destination = .edit(Trip.Draft(trip))
  }

  /// Present the filterable pool sheet for adding ideas to the shortlist.
  func addIdeasButtonTapped() {
    destination = .addIdeas
  }

  /// Drill into a pulled idea's read-only detail (Trip Ideas row tap / Itinerary
  /// info button) — an in-panel push, not a sheet.
  func showDetail(_ idea: Idea) {
    detailIdeaID = idea.id
  }

  /// Resolve the pushed detail's idea, or nil if it was deleted while open
  /// (ADR-0007 read-time reconciliation) — the destination pops itself then.
  func ideaForDetail(_ id: Idea.ID) -> Idea? { ideaByID[id] }

  /// This idea's place on the itinerary, *if* it's a scheduled stop on the trip —
  /// drives the detail's "On the Itinerary" section (nil for a plain pool idea, so
  /// the Trip Ideas drill-down stays placement-free).
  func stopContext(for idea: Idea) -> StopDetailContext? {
    guard let entry = entries.first(where: { $0.ideaID == idea.id && $0.status == .scheduled })
    else { return nil }
    let schedule = entry.schedule
    let label = schedule.dayNumber.map { dayLabel($0, trip: trip) } ?? "To Be Scheduled"
    return StopDetailContext(dayLabel: label, schedule: schedule)
  }

  /// The names of an idea's tags, alphabetized — for the detail sheet.
  func tagNames(for idea: Idea) -> [String] {
    let ids = ideaTagIDs[idea.id] ?? []
    return tags
      .filter { ids.contains($0.id) }
      .map(\.name)
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  /// Each planner's rated interest in an idea (skipping unrated rows), ordered by
  /// name — the his/hers display on the detail sheet.
  func interests(for idea: Idea) -> [(planner: Planner, level: Interest)] {
    interestRows
      .filter { $0.ideaID == idea.id && $0.level != nil }
      .compactMap { row in
        guard let planner = planners.first(where: { $0.id == row.plannerID }),
          let level = row.level
        else { return nil }
        return (planner, level)
      }
      .sorted { $0.planner.displayName < $1.planner.displayName }
  }

  /// Pull an idea onto the trip as a "considering" maybe (the default + action).
  func pull(_ idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.pull(ideaID: ideaID, into: tripID, in: db)
      }
    }
  }

  /// Pull straight onto the ranked shortlist (one transaction).
  func pullToShortlist(_ idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.pull(ideaID: ideaID, into: tripID, in: db)
        try TripIdea.setStatus(.shortlisted, ideaID: ideaID, tripID: tripID, in: db)
      }
    }
  }

  func setStatus(_ status: TripIdeaStatus, for idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.setStatus(status, ideaID: ideaID, tripID: tripID, in: db)
      }
    }
  }

  func remove(_ idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.remove(ideaID: ideaID, from: tripID, in: db)
      }
    }
  }

  /// Toggle an idea's "considering" state from the Add Ideas sheet's bubble
  /// icon: pull it as considering if it's off the trip, demote a shortlisted one
  /// back to considering, or remove it if it's already considering. Scheduled
  /// stops are left alone (manage those from the Itinerary).
  func tapConsidering(_ idea: Idea) {
    switch status(for: idea) {
    case nil: pull(idea)
    case .considering: remove(idea)
    case .shortlisted: setStatus(.considering, for: idea)
    case .scheduled, .done, .skipped: break
    }
  }

  /// Toggle an idea's shortlist state from the Add Ideas sheet's star icon: pull
  /// straight to the shortlist, promote a considering one, or remove it if it's
  /// already shortlisted. Scheduled stops are left alone (can't remove a
  /// scheduled stop — unschedule it from the Itinerary first).
  func tapShortlist(_ idea: Idea) {
    switch status(for: idea) {
    case nil: pullToShortlist(idea)
    case .considering: setStatus(.shortlisted, for: idea)
    case .shortlisted: remove(idea)
    case .scheduled, .done, .skipped: break
    }
  }

  /// Persist a new shortlist order after a drag-to-reorder.
  func reorderShortlist(_ orderedEntryIDs: [TripIdea.ID]) {
    withErrorReporting {
      try database.write { db in
        try TripIdea.reorderShortlist(orderedEntryIDs, in: db)
      }
    }
  }

  // MARK: - Scheduling actions

  /// Present the "add a stop to the itinerary" sheet (pick a shortlisted idea +
  /// a day and time of day).
  func addStopButtonTapped() {
    destination = .scheduleStop
  }

  /// Commit a shortlisted idea to the itinerary without a day — it lands in the
  /// "To Be Scheduled" bucket, where the user assigns it a day.
  func sendToBeScheduled(_ idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.scheduleUnplaced(ideaID: ideaID, tripID: tripID, in: db)
      }
    }
  }

  /// Set a stop's day-relative placement (move it between days, add/clear a
  /// daypart or time). Marks it `scheduled`.
  func setSchedule(_ schedule: Schedule, for idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.schedule(schedule, ideaID: ideaID, tripID: tripID, in: db)
      }
    }
  }

  /// Pull a scheduled stop back to the shortlist.
  func unschedule(_ idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.unschedule(ideaID: ideaID, tripID: tripID, in: db)
      }
    }
  }

  /// Mark a stop done after the trip — flips the idea's pool `visited` flag
  /// (ADR-0004 feedback-to-pool).
  func markDone(_ idea: Idea) {
    let (tripID, ideaID) = (tripID, idea.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.markDone(ideaID: ideaID, tripID: tripID, in: db)
      }
    }
  }

  /// Mark a stop skipped — leaves the idea's `visited` flag untouched.
  func markSkipped(_ idea: Idea) {
    setStatus(.skipped, for: idea)
  }
}
