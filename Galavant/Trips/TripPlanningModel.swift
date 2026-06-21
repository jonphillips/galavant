import CasePaths
import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// The editable state of the custom-stop sheet — author a new freeform stop or
/// edit an existing one. `stopID == nil` means creating; a set id means editing
/// that stop in place (ADR-0010 Slice 3). `day` (nil = To Be Scheduled) is the
/// landing day chosen at create time; on edit, placement is the `StopMenu`'s job
/// and the picker is hidden. Identifiable so it drives a `.sheet(item:)` like
/// `Trip.Draft` does.
struct FreeformStopDraft: Identifiable {
  let id = UUID()
  var stopID: TripIdea.ID?
  var title = ""
  var note = ""
  var day: Int?
}

/// Which itinerary section a per-section "+" is adding into — a day, or the To
/// Be Scheduled bucket (`day == nil`). Identifiable so each tap drives a fresh
/// `.sheet(item:)` (ADR-0010 Slice 3).
struct PlaceIdeaTarget: Identifiable {
  let id = UUID()
  let day: Int?
}

/// The editable state of the lodging sheet — author a new stay or edit one in
/// place (ADR-0011). `stayID == nil` means creating. `ideaID` set means the stay
/// is backed by a pool hotel (chosen in the sheet's Hotel picker, or seeded by
/// "Stay here") and `title`/`note` are unused; `ideaID == nil` is a freeform stay
/// whose `title`/`note` carry it. `checkInDay`/`checkOutDay` are the span; optional
/// `"HH:mm"` times default to evening / morning ordering. Identifiable so each
/// presentation drives a fresh `.sheet(item:)`.
struct StayDraft: Identifiable {
  let id = UUID()
  var stayID: TripStay.ID?
  var ideaID: Idea.ID?
  var title = ""
  var note = ""
  var checkInDay = 1
  var checkOutDay = 2
  var checkInTime: String?
  var checkOutTime: String?

  /// Backed by a pool hotel (vs. a freeform stay) — the sheet hides the title
  /// field and shows the hotel name instead.
  var isIdeaBacked: Bool { ideaID != nil }
}

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
  @ObservationIgnored @FetchAll(TripStay.all) var allTripStays
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

  // ETA cache (docs/trip-canvas.md): travel times keyed by leg + mode.
  // Walking is always fetched first; legs ≥ autoSwitchThreshold auto-switch to
  // transit. Users can override per-leg; driving is always in the menu.
  var travelTimes: [LegKey: [TransportMode: TravelTime]] = [:]
  var modeOverrides: [LegKey: TransportMode] = [:]
  private var isFetchingETAs = false
  private var pendingETAFetch = false

  static let autoSwitchThreshold: TimeInterval = 20 * 60  // 20 minutes
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
    case placeIdea(PlaceIdeaTarget)
    case freeformStop(FreeformStopDraft)
    case stay(StayDraft)
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
  private var stays: [TripStay] { allTripStays.filter { $0.tripID == tripID } }
  private var ideaByID: [Idea.ID: Idea] {
    Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// This trip's resolved planning read-model — the joins, projections, and
  /// canvas geometry live in the tested functional core (`TripPlan`), not here.
  /// Views read `model.plan.shortlist`, `model.plan.itinerary`, etc.; the model
  /// keeps only UI state and the db-write actions.
  var plan: TripPlan {
    TripPlan(
      entries: entries, ideasByID: ideaByID,
      lengthInDays: trip?.lengthInDays ?? 1, tripStays: stays)
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
    Dictionary(
      entries.compactMap { entry in entry.ideaID.map { ($0, entry.status) } },
      uniquingKeysWith: { first, _ in first }
    )
  }

  /// This idea's status on the trip, or nil if it hasn't been pulled.
  func status(for idea: Idea) -> TripIdeaStatus? { statusByIdea[idea.id] }

  /// Pool hotels (kind `.stay`) the lodging editor can attach a stay to, name-
  /// ordered (the pool is already name-sorted). Tying a stay to a located hotel is
  /// what puts it on the map (ADR-0011).
  var lodgingIdeas: [Idea] { ideas.filter { $0.kind == .stay } }

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

  // MARK: - ETA mode resolution

  /// The effective transport mode for a leg: user override > auto-detect.
  /// Auto-detect: walking ≥ 20 min → transit (best guess for long legs).
  func effectiveMode(for leg: LegKey) -> TransportMode {
    if let override = modeOverrides[leg] { return override }
    if let walking = travelTimes[leg]?[.walking],
      walking.seconds >= Self.autoSwitchThreshold {
      return .transit
    }
    return .walking
  }

  /// Pre-computed effective modes for all legs — passed into `itineraryItems`
  /// so the pure plan function doesn't need to call back into the model.
  var effectiveModes: [LegKey: TransportMode] {
    Dictionary(plan.allLegs.map { ($0, effectiveMode(for: $0)) },
               uniquingKeysWith: { first, _ in first })
  }

  /// User-override the transport mode for a leg. Triggers an ETA fetch for
  /// the new mode if it isn't already cached.
  func setMode(_ mode: TransportMode, for leg: LegKey) {
    modeOverrides[leg] = mode
    Task { await fetchMissingETAs() }
  }

  // MARK: - ETA fetch

  /// Fetch ETAs for uncached legs, sequentially (MKDirections: one in-flight
  /// request at a time). Per leg:
  ///   1. Always fetch walking.
  ///   2. If walking ≥ threshold and no user override, fetch transit (auto-switch).
  ///   3. If the user overrode to a mode we haven't fetched yet, fetch it.
  /// If called while already running, enqueues one re-run for after.
  func fetchMissingETAs() async {
    if isFetchingETAs { pendingETAFetch = true; return }
    isFetchingETAs = true
    defer {
      isFetchingETAs = false
      if pendingETAFetch {
        pendingETAFetch = false
        Task { await fetchMissingETAs() }
      }
    }
    for leg in plan.allLegs {
      guard !Task.isCancelled else { break }
      // Step 1: walking — always the baseline.
      if travelTimes[leg]?[.walking] == nil,
        let tt = try? await directionsClient.calculateETA(leg, .walking) {
        travelTimes[leg, default: [:]][.walking] = tt
      }
      guard !Task.isCancelled else { break }
      // Step 2: auto-switch — if walking is long and the user hasn't overridden,
      // pre-fetch transit so the connector can show it without a second wait.
      let walkingTime = travelTimes[leg]?[.walking]
      let longLeg = (walkingTime?.seconds ?? 0) >= Self.autoSwitchThreshold
      if longLeg, modeOverrides[leg] == nil, travelTimes[leg]?[.transit] == nil,
        let tt = try? await directionsClient.calculateETA(leg, .transit) {
        travelTimes[leg, default: [:]][.transit] = tt
      }
      guard !Task.isCancelled else { break }
      // Step 3: user override — fetch the chosen mode if not yet cached.
      if let override = modeOverrides[leg], travelTimes[leg]?[override] == nil,
        let tt = try? await directionsClient.calculateETA(leg, override) {
        travelTimes[leg, default: [:]][override] = tt
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

  func setStatus(_ status: TripIdeaStatus, for stopID: TripIdea.ID) {
    withErrorReporting {
      try database.write { db in
        try TripIdea.setStatus(status, stopID: stopID, in: db)
      }
    }
  }

  func remove(_ stopID: TripIdea.ID) {
    withErrorReporting {
      try database.write { db in
        try TripIdea.remove(stopID: stopID, in: db)
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
    case .considering:
      if let id = entryID(for: idea) { remove(id) }
    case .shortlisted:
      if let id = entryID(for: idea) { setStatus(.considering, for: id) }
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
    case .considering:
      if let id = entryID(for: idea) { setStatus(.shortlisted, for: id) }
    case .shortlisted:
      if let id = entryID(for: idea) { remove(id) }
    case .scheduled, .done, .skipped: break
    }
  }

  /// The TripIdea row for a pool idea on this trip, if it has been pulled.
  private func entryID(for idea: Idea) -> TripIdea.ID? {
    entries.first { $0.ideaID == idea.id }?.id
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

  /// Present the per-section idea picker — pick a shortlisted idea to drop into
  /// `day` (nil = the To Be Scheduled bucket). Driven by a section header's "+".
  func addToSectionTapped(day: Int?) {
    destination = .placeIdea(PlaceIdeaTarget(day: day))
  }

  /// Commit the per-section picker: place a shortlisted idea onto its target
  /// day (anytime — refine the time later via `StopMenu`) or into the bucket.
  func placeIdea(_ stopID: TripIdea.ID, on day: Int?) {
    if let day {
      setSchedule(.day(day), for: stopID)
    } else {
      sendToBeScheduled(stopID)
    }
    destination = nil
  }

  /// Present the custom-stop editor to author a new freeform stop ("lunch",
  /// "train to Aarhus", "check in"). Defaults to the To-Be-Scheduled bucket; the
  /// sheet's day picker can land it on a day directly (ADR-0010).
  func addCustomStopButtonTapped() {
    destination = .freeformStop(FreeformStopDraft())
  }

  /// Re-open the editor seeded from an existing freeform stop. No-op on an
  /// idea-backed stop (those edit through the pool idea, not here).
  func editFreeform(_ stop: ResolvedStop) {
    guard case let .freeform(title, note) = stop.content else { return }
    destination = .freeformStop(
      FreeformStopDraft(stopID: stop.id, title: title, note: note ?? "", day: stop.entry.dayNumber))
  }

  /// Commit the custom-stop editor: create a new stop (placed on its chosen day,
  /// or left in the bucket), or update the edited one's content. A blank title
  /// is dropped (the sheet's Save is disabled, but guard anyway).
  func saveFreeform(_ draft: FreeformStopDraft) {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, let tripID = trip?.id else { return }
    let trimmedNote = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
    let note = trimmedNote.isEmpty ? nil : trimmedNote
    withErrorReporting {
      try database.write { db in
        if let stopID = draft.stopID {
          try TripIdea.editFreeform(stopID: stopID, title: title, note: note, in: db)
        } else {
          let id = try TripIdea.createFreeform(tripID: tripID, title: title, note: note, in: db)
          if let day = draft.day {
            try TripIdea.schedule(.day(day), stopID: id, in: db)
          }
        }
      }
    }
    destination = nil
  }

  // MARK: - Stays (accommodations, ADR-0011)

  /// "Add lodging" — present the lodging editor for a new freeform stay. Defaults
  /// to nights 1→2; the sheet picks the span and (optionally) the hotel.
  func addLodgingButtonTapped() {
    destination = .stay(StayDraft(checkOutDay: min(2, max(2, trip?.lengthInDays ?? 2))))
  }

  /// "Stay here" — present the lodging editor seeded from a pool hotel. The span
  /// defaults to the whole trip (a reasonable first guess for the one place you're
  /// staying); the user trims it.
  func stayHere(_ idea: Idea) {
    let last = max(2, trip?.lengthInDays ?? 2)
    destination = .stay(StayDraft(
      ideaID: idea.id, checkInDay: 1, checkOutDay: last))
  }

  /// Re-open the lodging editor seeded from an existing stay.
  func editStay(_ resolved: ResolvedStay) {
    let stay = resolved.stay
    var title = ""
    var note = ""
    if case let .freeform(t, n) = resolved.content {
      title = t
      note = n ?? ""
    }
    destination = .stay(StayDraft(
      stayID: stay.id, ideaID: stay.ideaID,
      title: title, note: note,
      checkInDay: stay.checkInDay, checkOutDay: stay.checkOutDay,
      checkInTime: stay.checkInTime, checkOutTime: stay.checkOutTime))
  }

  /// Commit the lodging editor: create or update the stay. A freeform stay needs a
  /// non-empty title (the sheet's Save is gated, but guard anyway); the span is
  /// coerced valid by the write op.
  func saveStay(_ draft: StayDraft) {
    guard let tripID = trip?.id else { return }
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedNote = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
    let note = trimmedNote.isEmpty ? nil : trimmedNote
    withErrorReporting {
      try database.write { db in
        if let stayID = draft.stayID {
          try TripStay.edit(
            stayID: stayID, ideaID: draft.ideaID,
            title: title.isEmpty ? nil : title, note: note,
            checkInDay: draft.checkInDay, checkOutDay: draft.checkOutDay,
            checkInTime: draft.checkInTime, checkOutTime: draft.checkOutTime, in: db)
        } else if let ideaID = draft.ideaID {
          try TripStay.create(
            tripID: tripID, ideaID: ideaID,
            checkInDay: draft.checkInDay, checkOutDay: draft.checkOutDay,
            checkInTime: draft.checkInTime, checkOutTime: draft.checkOutTime, in: db)
        } else {
          guard !title.isEmpty else { return }
          try TripStay.createFreeform(
            tripID: tripID, title: title, note: note,
            checkInDay: draft.checkInDay, checkOutDay: draft.checkOutDay,
            checkInTime: draft.checkInTime, checkOutTime: draft.checkOutTime, in: db)
        }
      }
    }
    destination = nil
  }

  /// Delete a stay from the trip.
  func removeStay(_ stayID: TripStay.ID) {
    withErrorReporting {
      try database.write { db in
        try TripStay.remove(stayID: stayID, in: db)
      }
    }
  }

  /// Commit a stop to the itinerary without a day — it lands in the "To Be
  /// Scheduled" bucket, where the user assigns it a day.
  func sendToBeScheduled(_ stopID: TripIdea.ID) {
    withErrorReporting {
      try database.write { db in
        try TripIdea.scheduleUnplaced(stopID: stopID, in: db)
      }
    }
  }

  /// Set a stop's day-relative placement (move it between days, add/clear a
  /// daypart or time). Marks it `scheduled`.
  func setSchedule(_ schedule: Schedule, for stopID: TripIdea.ID) {
    withErrorReporting {
      try database.write { db in
        try TripIdea.schedule(schedule, stopID: stopID, in: db)
      }
    }
  }

  /// Pull a stop back to the shortlist. Freeform stops skip the shortlist per
  /// ADR-0010 — call `remove` instead.
  func unschedule(_ stopID: TripIdea.ID) {
    withErrorReporting {
      try database.write { db in
        try TripIdea.unschedule(stopID: stopID, in: db)
      }
    }
  }

  /// Mark a stop done after the trip. For idea-backed stops also flips the pool
  /// idea's `visited` flag (ADR-0004 feedback-to-pool).
  func markDone(_ stopID: TripIdea.ID) {
    withErrorReporting {
      try database.write { db in
        try TripIdea.markDone(stopID: stopID, in: db)
      }
    }
  }

  /// Mark a stop skipped — leaves any associated pool idea's `visited` flag untouched.
  func markSkipped(_ stopID: TripIdea.ID) {
    setStatus(.skipped, for: stopID)
  }
}
