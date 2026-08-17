import CasePaths
import Dependencies
import Foundation
import GalavantAI
import GalavantPlaces
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
  var alternativeToStopID: TripIdea.ID?
  var title = ""
  var note = ""
  var day: Int?
}

struct AlternativeSourceTarget: Identifiable {
  let id = UUID()
  let targetStopID: TripIdea.ID
}

struct AlternativeSlotTarget: Identifiable {
  let id = UUID()
  let sourceStopID: TripIdea.ID
}

/// Which itinerary section a per-section "+" is adding into — a day, or the To
/// Be Scheduled bucket (`day == nil`). Identifiable so each tap drives a fresh
/// `.sheet(item:)` (ADR-0010 Slice 3).
struct PlaceIdeaTarget: Identifiable {
  let id = UUID()
  let day: Int?
}

/// A place selected directly from the Apple Maps canvas, awaiting the normal
/// confirm-and-tweak idea form. The UUID gives every tap its own sheet identity.
struct MapPlaceIdea: Identifiable {
  let id = UUID()
  let draft: Idea.Draft
}

/// An existing pool idea opened from an itinerary row. The draft is wrapped so
/// presentation has stable identity even before a new idea has been persisted.
struct TripIdeaEditPresentation: Identifiable {
  let id: UUID
  let draft: Idea.Draft

  init(_ idea: Idea) {
    id = idea.id
    draft = Idea.Draft(idea)
  }
}

/// The editable state of the stop clock-time editor (ADR-0033 Slice 4) — give a
/// placed stop an exact `.timed` start (and optional end) on its `day`. `start`
/// is pre-filled from `Schedule.suggestedTime` over the stop's ordered-day
/// neighbors (or its own start when already timed); `end` mirrors the stay
/// editor's optional-time toggle. Identifiable (keyed on the stop) so it drives a
/// `.sheet(item:)`.
struct StopTimeDraft: Identifiable {
  var stopID: TripIdea.ID
  var day: Int
  var start: String
  var end: String?
  var id: TripIdea.ID { stopID }
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

/// The editable state of the stop-note editor — a stop's short trip-specific
/// caption (`TripIdea.inlineNote`), the "why it's on the itinerary" nudge shown
/// under its title. Seeded from the stop's current note; a blank field clears it.
/// Identifiable (keyed on the stop) so it drives a `.sheet(item:)`.
struct StopNoteDraft: Identifiable {
  var stopID: TripIdea.ID
  var stopTitle: String
  var note: String
  var id: TripIdea.ID { stopID }
}

/// The editable state of the reservation-pin sheet (docs/trip-time-model.md §4)
/// — give a stop an absolute calendar date plus optional booking metadata, or
/// (from the sheet's destructive action) drop its pin back to an ordinary
/// day-relative stop. `isEditing` distinguishes an existing pin (seeded from its
/// current fields) from a fresh one (seeded from the stop's current placement or
/// today). `partySize` stays a free-text field, parsed to `Int?` on save, so an
/// empty field round-trips to "not set" without a separate toggle. Identifiable
/// (keyed on the stop) so it drives a `.sheet(item:)`.
struct BookingDraft: Identifiable {
  var stopID: TripIdea.ID
  var isEditing: Bool
  var date: Date
  var confirmationNumber = ""
  var bookingURL = ""
  var partySize = ""
  var id: TripIdea.ID { stopID }
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
  @ObservationIgnored @Dependency(\.calendarReconciliationHistoryStore) var calendarHistoryStore
  @ObservationIgnored @Dependency(\.handoffSessionStore) var handoffSessionStore
  @ObservationIgnored @Dependency(\.date) var date
  @ObservationIgnored @FetchAll(Trip.all) var trips
  @ObservationIgnored @FetchAll(Idea.order(by: \.name)) var ideas
  @ObservationIgnored @FetchAll(TripIdea.all) var allTripIdeas
  @ObservationIgnored @FetchAll(TripStay.all) var allTripStays
  @ObservationIgnored @FetchAll(TripRegion.all) var allTripRegions
  @ObservationIgnored @FetchAll(TripDayRegion.all) var allTripDayRegions
  @ObservationIgnored @FetchAll(TripTravelModeOverride.all) var allTravelModeOverrides
  @ObservationIgnored @FetchAll(CalendarTripConstraint.all) var allCalendarConstraints
  @ObservationIgnored @FetchAll(CalendarPlanRepair.all) var allCalendarPlanRepairs
  @ObservationIgnored @FetchAll(MapRegion.order(by: \.name)) var regions
  @ObservationIgnored @FetchAll(Tag.order(by: \.name)) var tags
  @ObservationIgnored @FetchAll(IdeaTag.all) var ideaTags
  @ObservationIgnored @FetchAll(Planner.all) var planners
  @ObservationIgnored @FetchAll(IdeaInterest.all) var interestRows
  @ObservationIgnored @FetchAll(IdeaEvaluation.all) var allEvaluations

  let tripID: Trip.ID
  var destination: Destination?
  var recommendationReview: [RecommendationCandidateDraft] = []
  var recommendationHandoffError: String?
  /// Non-blocking heads-up when a paste imported despite a dropped token or an
  /// out-of-date contract marker (warn-not-block, ADR-0036 handoff ergonomics).
  var recommendationHandoffWarning: String?
  var calendarLocalState: CalendarReconciliationLocalState

  /// The idea drilled into on the in-panel detail push (nil = the list root). A
  /// push within the panel, not a sheet, so it never covers the map; driven by ID
  /// so it resolves live and stays out of `Hashable`.
  var detailIdeaID: Idea.ID?

  // Canvas state (M3d): the map is the trip's home. `canvasSelectedDay` is the
  // day lens (nil = the whole trip, all days color-coded); `canvasSelectedStopID`
  // is the one selection the map pins and the timeline rows both project.
  var canvasSelectedDay: Int?
  var canvasSelectedStopID: TripIdea.ID?
  var expandedAlternativeGroupIDs: Set<UUID> = []

  // ETA cache (docs/trip-canvas.md): travel times keyed by leg + mode. A trip's
  // main mode is the shared default; the per-leg menu remains a local override.
  // Trips without a main mode retain the original walking→transit auto choice.
  var travelTimes: [LegKey: [TransportMode: TravelTime]] = [:]
  /// Immediate local projection of a choice while the persisted query refreshes.
  var modeOverrides: [LegKey: TransportMode] = [:]
  // Non-private so the ETA-fetch loop can live with the rest of the directions
  // subsystem in TripPlanningModel+Directions.swift (stored state must stay here).
  var isFetchingETAs = false
  var pendingETAFetch = false

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
    case addIdeas
    case mapPlaceIdea(MapPlaceIdea)
    case idea(TripIdeaEditPresentation)
    case placeIdea(PlaceIdeaTarget)
    case freeformStop(FreeformStopDraft)
    case alternativeSource(AlternativeSourceTarget)
    case alternativeSlot(AlternativeSlotTarget)
    case stay(StayDraft)
    case stopTime(StopTimeDraft)
    case stopNote(StopNoteDraft)
    case booking(BookingDraft)
    case recommendationHandoff(RecommendationHandoffPresentation)
    case recommendationWorkspace(RecommendationWorkspacePresentation)
  }

  init(tripID: Trip.ID) {
    @Dependency(\.calendarReconciliationHistoryStore) var calendarHistoryStore
    self.tripID = tripID
    calendarLocalState = calendarHistoryStore.state(tripID)
    // Opening a trip to plan it is the strongest "this is the trip I'm working on"
    // signal — record it so a share-extension capture defaults onto it.
    recentTripStore.record(tripID)
  }

  // MARK: - Derived state

  var trip: Trip? { trips.first { $0.id == tripID } }

  private var entries: [TripIdea] { allTripIdeas.filter { $0.tripID == tripID } }
  private var stays: [TripStay] { allTripStays.filter { $0.tripID == tripID } }
  private var dayRegions: [TripDayRegion] { allTripDayRegions.filter { $0.tripID == tripID } }
  private var calendarConstraints: [CalendarTripConstraint] {
    allCalendarConstraints.filter { $0.tripID == tripID }
  }
  var calendarPlanRepairs: [CalendarPlanRepair] {
    allCalendarPlanRepairs.filter { $0.tripID == tripID }
  }
  private var ideaByID: [Idea.ID: Idea] {
    Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
  private var regionByID: [MapRegion.ID: MapRegion] {
    Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// This trip's resolved planning read-model — the joins, projections, and
  /// canvas geometry live in the tested functional core (`TripPlan`), not here.
  /// Views read `model.plan.shortlist`, `model.plan.itinerary`, etc.; the model
  /// keeps only UI state and the db-write actions.
  var plan: TripPlan {
    TripPlan(
      entries: entries, ideasByID: ideaByID,
      lengthInDays: trip?.lengthInDays ?? 1, tripStays: stays,
      dayRegions: dayRegions, regionsByID: regionByID,
      calendarConstraints: calendarConstraints)
  }

  // MARK: - Start-day solver (ADR-0029 §5)

  /// The keyed stops that constrain the start weekday — scheduled, day-placed stops
  /// whose pool idea carries structured hours. Empty until hours coverage lands, which
  /// is exactly when the solver has nothing to say.
  var startDaySolverStops: [SolverStop] {
    StartDaySolver.stops(entries: entries, ideasByID: ideaByID)
  }

  /// The solver's per-start-weekday verdicts, ranked cleanest-first for the panel.
  /// Advisory only — nothing here moves a stop or changes the start (ADR-0004).
  var startDayOptions: [StartDayOption] {
    StartDaySolver.solve(stops: startDaySolverStops)
      .sorted { $0.conflicts.count < $1.conflicts.count }
  }

  /// The weekday the trip currently starts on, when it's dated — the panel marks it.
  var currentStartWeekday: Weekday? {
    trip?.startDate.flatMap { Weekday.from($0) }
  }

  /// When each stop's hours were last verified — the panel shows this next to a
  /// conflict so "closed Mondays" reads as "…as of when we saved it" (ADR-0029 §5).
  var stopHoursVerifiedAt: [TripIdea.ID: Date] {
    Dictionary(
      uniqueKeysWithValues: entries.compactMap { entry in
        guard let ideaID = entry.ideaID, let date = ideaByID[ideaID]?.hoursVerifiedAt
        else { return nil }
        return (entry.id, date)
      }
    )
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

  // MARK: - Actions

  /// Present the filterable pool sheet for adding ideas to the shortlist.
  func addIdeasButtonTapped() {
    destination = .addIdeas
  }

  /// Start a normal idea edit from a POI the person tapped on the trip map. The
  /// `Place` carries the canonical Maps identifier, so this avoids re-searching a
  /// name the map already resolved.
  func mapPlaceTapped(_ place: Place) async {
    let draft = await MapPlaceCapture().draft(for: place)
    destination = .mapPlaceIdea(
      MapPlaceIdea(
        draft: draft
      )
    )
  }

  /// After a newly map-picked idea saves successfully, pull it onto this trip's
  /// shortlist. The save callback never fires when the idea write fails.
  func addNewIdeaToShortlist(_ ideaID: Idea.ID) {
    let tripID = tripID
    _ = withErrorReporting {
      try database.write { db in
        try TripIdea.pull(ideaID: ideaID, into: tripID, in: db)
        try TripIdea.setStatus(.shortlisted, ideaID: ideaID, tripID: tripID, in: db)
      }
    }
  }

  func mapPlaceIdeaSaved(_ ideaID: Idea.ID) async {
    addNewIdeaToShortlist(ideaID)
    await MapPlaceCapture().enrichIfNeeded(ideaID: ideaID)
  }

  /// Drill into a pulled idea's read-only detail (Trip Ideas row tap / Itinerary
  /// info button) — an in-panel push, not a sheet.
  func showDetail(_ idea: Idea) {
    detailIdeaID = idea.id
  }

  /// Edit the pool idea behind an itinerary row. The stop's placement remains
  /// untouched; this is specifically for correcting a captured/display title.
  func editIdea(_ idea: Idea) {
    destination = .idea(TripIdeaEditPresentation(idea))
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

  /// Source evaluations for an idea, orphan-drops applied. Most-recently-recorded
  /// first — the evaluations detail section's data source (ADR-0015).
  func evaluations(for idea: Idea) -> [IdeaEvaluation] {
    IdeaEvaluation.evaluations(
      forIdea: idea.id,
      from: allEvaluations,
      knownIdeaIDs: Set(ideas.map(\.id))
    )
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

  // Scheduling, stays, and per-day region actions live in
  // TripPlanningModel+Scheduling.swift.
}

// MARK: - Calendar-derived start anchors (ADR-0034 §8)

extension TripPlanningModel {
  /// Calendar-linked absolute commitments constrain the relative start date. The
  /// EventKit binding supplies the destination zone used when it was observed;
  /// an absolute event without that zone remains a reconciliation item rather
  /// than falling back to this device's clock.
  var startDayAnchors: [TripStartAnchor] {
    calendarLocalState.linkedStops.compactMap { linked in
      guard let entry = entries.first(where: { $0.id == linked.stopID }),
        let dayNumber = entry.dayNumber,
        let commitmentDate = civilDate(for: linked)
      else { return nil }
      let name = entry.ideaID.flatMap { ideaByID[$0]?.name }
        ?? entry.inlineTitle
        ?? linked.eventTitle
        ?? "Linked calendar commitment"
      return TripStartAnchor(
        stopID: entry.id, stopName: name, dayNumber: dayNumber,
        commitmentDate: commitmentDate)
    }
  }

  var startDayAnchorAssessment: StartDayAnchorAssessment {
    StartDaySolver.assess(anchors: startDayAnchors)
  }

  private func civilDate(for linked: CalendarLinkedStop) -> CalendarCivilDate? {
    switch linked.commitment.temporal {
    case let .absolute(start, _, _):
      guard let timeZone = linked.itineraryTimeZone else { return nil }
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      return CalendarCivilDate(start, calendar: calendar)
    case let .floating(start, _):
      return start.date
    case let .allDay(start, _):
      return start
    }
  }
}
