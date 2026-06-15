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
  }

  // MARK: - Derived state

  var trip: Trip? { trips.first { $0.id == tripID } }

  private var entries: [TripIdea] { allTripIdeas.filter { $0.tripID == tripID } }
  private var ideaByID: [Idea.ID: Idea] {
    Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// Shortlisted-but-not-yet-scheduled entries in rank order (orphans whose idea
  /// was deleted from the pool are dropped — ADR-0007 read-time reconciliation).
  /// The Ideas page's Shortlist section *and* the Itinerary's Add-Stop sheet draw
  /// from this same set.
  var shortlistOnly: [Resolved] {
    entries
      .filter { $0.status == .shortlisted }
      .sorted { $0.shortlistRank < $1.shortlistRank }
      .compactMap(resolve)
  }

  /// Scheduled stops, ordered as they sit on the itinerary (day, then time of
  /// day) — the Ideas page's Scheduled section.
  var scheduledStops: [Resolved] {
    entries
      .filter { $0.status == .scheduled }
      .sorted {
        ($0.dayNumber ?? 0, $0.schedule.intraDaySort, $0.shortlistRank)
          < ($1.dayNumber ?? 0, $1.schedule.intraDaySort, $1.shortlistRank)
      }
      .compactMap(resolve)
  }

  var considering: [Resolved] {
    TripIdea.considering(entries).compactMap(resolve)
  }

  /// Nothing pulled onto the trip at all — drives the Ideas page empty state.
  var hasNoPlanningItems: Bool {
    shortlistOnly.isEmpty && scheduledStops.isEmpty && considering.isEmpty
  }

  private func resolve(_ entry: TripIdea) -> Resolved? {
    ideaByID[entry.ideaID].map { Resolved(entry: entry, idea: $0) }
  }

  /// A pulled entry joined to its idea, for the planning rows.
  struct Resolved: Identifiable {
    var entry: TripIdea
    var idea: Idea
    var id: TripIdea.ID { entry.id }
  }

  // MARK: - Itinerary mode (scheduled stops laid out by day)

  /// The trip's days 1…N, each with its resolved scheduled stops in order
  /// (orphans dropped, ADR-0007).
  var itinerary: [ResolvedDay] {
    let length = trip?.lengthInDays ?? 1
    return TripIdea.itinerary(entries, lengthInDays: length).map { day in
      ResolvedDay(number: day.number, stops: day.stops.compactMap(resolve))
    }
  }

  /// True once at least one stop is scheduled — drives the empty state.
  var hasScheduledStops: Bool { entries.contains { $0.status == .scheduled } }

  /// Scheduled stops not yet placed on a day — the "To Be Scheduled" bucket at
  /// the top of the Itinerary (orphans dropped).
  var toBeScheduledStops: [Resolved] {
    TripIdea.toBeScheduled(entries).compactMap(resolve)
  }

  /// One itinerary day with its resolved stops, for the day sections.
  struct ResolvedDay: Identifiable {
    var number: Int
    var stops: [Resolved]
    var id: Int { number }
  }

  // MARK: - Canvas mode (the map is the trip's home, M3d)

  /// The trip's days with their resolved scheduled stops — the canvas reads this
  /// to lay out numbered pins and per-day polylines. (Alias of `itinerary`, named
  /// for the surface that consumes it.)
  var canvasDays: [ResolvedDay] { itinerary }

  /// True when at least one scheduled stop carries coordinates to plot.
  var hasLocatedStops: Bool {
    itinerary.contains { day in
      day.stops.contains { $0.idea.latitude != nil && $0.idea.longitude != nil }
    }
  }

  /// Coordinates of the located scheduled stops to frame the camera on: one day's
  /// when `day` is set, the whole trip's when nil. Ordered as they sit on the
  /// itinerary; feeds the pure `MapFraming.box`.
  func framingCoordinates(forDay day: Int?) -> [(latitude: Double, longitude: Double)] {
    let days = day.map { d in itinerary.filter { $0.number == d } } ?? itinerary
    return days.flatMap(\.stops).compactMap { resolved in
      guard let lat = resolved.idea.latitude, let lon = resolved.idea.longitude
      else { return nil }
      return (latitude: lat, longitude: lon)
    }
  }

  /// A day's located stops in itinerary order — the route the pins and the
  /// polyline follow. Unlocated stops are dropped here (they still list in the
  /// timeline). The view assigns the 1-based sequence number by position.
  func locatedStops(forDay day: Int) -> [Resolved] {
    (itinerary.first { $0.number == day }?.stops ?? [])
      .filter { $0.idea.latitude != nil && $0.idea.longitude != nil }
  }

  /// The map regions this trip is scoped to — the camera's fallback frame when no
  /// stops have coordinates yet.
  var tripRegions: [MapRegion] { regions.filter { tripRegionIDs.contains($0.id) } }

  /// On first appear, land on Ideas rather than Itinerary when nothing is
  /// scheduled yet, so an empty map isn't a dead end. Runs once.
  func pickInitialSheetTabIfNeeded() {
    guard !didPickInitialTab else { return }
    didPickInitialTab = true
    sheetTab = hasScheduledStops ? .itinerary : .ideas
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

  /// Route dragged stops to their dropped itinerary section — the reorder
  /// container's move (usually one stop, but the API hands back a list).
  func moveStops(_ stopIDs: [TripIdea.ID], to section: ItinerarySection) {
    for id in stopIDs {
      switch section {
      case .bucket: moveStopToBeScheduled(id)
      case let .day(day): moveStop(id, toDay: day)
      }
    }
  }

  /// Drop a stop (by its trip-idea row) onto `day` — the drag-between-days gesture
  /// on the itinerary. Keeps its time-of-day granularity (`schedule.onDay`).
  func moveStop(_ stopID: TripIdea.ID, toDay day: Int) {
    guard let resolved = resolvedStop(stopID) else { return }
    setSchedule(resolved.entry.schedule.onDay(day), for: resolved.idea)
  }

  /// Drop a stop back into the dayless "To Be Scheduled" bucket — the drag
  /// counterpart to the `StopMenu`'s "To Be Scheduled".
  func moveStopToBeScheduled(_ stopID: TripIdea.ID) {
    guard let resolved = resolvedStop(stopID) else { return }
    sendToBeScheduled(resolved.idea)
  }

  /// Resolve a dragged stop back to its entry + idea (nil if the row vanished
  /// mid-drag, e.g. a sync delete — the drop is then a no-op).
  private func resolvedStop(_ id: TripIdea.ID) -> Resolved? {
    entries.first { $0.id == id }.flatMap(resolve)
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
