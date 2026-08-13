import Foundation
import SQLiteData

// swiftlint:disable file_length
// Trip lifecycle transitions stay together so their shared-status invariants are
// auditable in one transactional API surface.
extension Trip {
  /// Create a trip attached to the default travel party and return it. A new
  /// `someday` trip is appended to the bottom of the backlog regardless of the
  /// rank carried in `certainty` — the form never has to pick a position.
  public static func create(
    name: String,
    certainty: Certainty = .someday(rank: 0),
    lengthInDays: Int = 7,
    notes: String = "",
    mainTransportMode: TransportMode? = nil,
    in db: Database
  ) throws -> Trip {
    let partyID = try TravelParty.ensureDefault(in: db).id
    var certainty = certainty
    if certainty.stage == .someday {
      certainty = .someday(rank: try nextSomedayRank(in: db))
    }
    let id = UUID()
    var draft = Trip.Draft(Trip(id: id, name: name, notes: notes, lengthInDays: lengthInDays,
      mainTransportMode: mainTransportMode, travelPartyID: partyID))
    draft.apply(certainty)
    try Trip.insert { draft }.execute(db)
    guard let created = try Trip.find(id).fetchOne(db) else {
      throw TripError.creationFailed
    }
    return created
  }

  /// Persist edits to an existing trip from its form draft + chosen certainty.
  /// Moving a trip *into* the someday backlog from another stage appends it to
  /// the bottom; staying in someday preserves its rank. Sets the party FK and
  /// upserts. (New trips go through `create` instead.)
  ///
  /// When this changes (or sets, via a certainty transition into `.dated`) the
  /// trip's `startDate`, every pinned reservation (`TripIdea.pinnedDate != nil`)
  /// on the trip has its `dayNumber` re-derived so it keeps its absolute calendar
  /// date rather than sliding with the trip (docs/trip-time-model.md §4). An
  /// undated trip (or one leaving `.dated`) has no `startDate` to re-derive
  /// against, so pinned stops are left untouched — their pin holds inert until
  /// the trip is dated.
  public static func update(_ draft: Trip.Draft, certainty: Certainty, in db: Database) throws {
    var draft = draft
    var certainty = certainty
    if certainty.stage == .someday, draft.certaintyStage != .someday {
      certainty = .someday(rank: try nextSomedayRank(in: db))
    }
    let priorStartDate = try draft.id.flatMap { try Trip.find($0).fetchOne(db) }?.startDate
    draft.apply(certainty)
    draft.travelPartyID = try TravelParty.ensureDefault(in: db).id
    try Trip.upsert { draft }.execute(db)
    if let tripID = draft.id, let newStartDate = certainty.startDate, newStartDate != priorStartDate {
      try TripIdea.rederivePinnedStops(tripID: tripID, startDate: newStartDate, in: db)
    }
  }

  /// The next free backlog position — one past the current bottom (or 0 when the
  /// backlog is empty). Filtered in Swift; a household has a handful of trips.
  static func nextSomedayRank(in db: Database) throws -> Int {
    let ranks = try Trip.all.fetchAll(db)
      .filter { $0.certaintyStage == .someday }
      .map(\.somedayRank)
    return (ranks.max() ?? -1) + 1
  }

  /// Persist a new someday-backlog order: each trip's `somedayRank` becomes its
  /// index in `orderedIDs`. Call after a drag-to-reorder.
  public static func reorderSomeday(_ orderedIDs: [Trip.ID], in db: Database) throws {
    for (index, id) in orderedIDs.enumerated() {
      try Trip.find(id).update { $0.somedayRank = index }.execute(db)
    }
  }

  /// Set (or, with `nil`, clear) the trip's Unsplash header-image reference
  /// (ADR-0032). The four columns move together — a chosen photo writes all four,
  /// clearing (passing `nil`) wipes all four — so the header is always
  /// all-present or all-absent. The caller is responsible for the ToS
  /// `registerDownload` ping before persisting a selection (`TripHeaderPicker`).
  public static func setHeaderImage(
    _ image: TripHeaderImage?,
    tripID: Trip.ID,
    in db: Database
  ) throws {
    try Trip.find(tripID)
      .update {
        $0.headerImageURL = #bind(image?.url)
        $0.headerImageColor = #bind(image?.color)
        $0.headerPhotographerName = #bind(image?.photographerName)
        $0.headerPhotographerUsername = #bind(image?.photographerUsername)
      }
      .execute(db)
  }

  // MARK: - Pure sectioning (functional core)

  /// Split trips into the three certainty sections, each in its own natural
  /// order: someday by backlog rank, targeted by year then quarter, dated by
  /// start date. Pure — no I/O — so it's the densely-tested core.
  public static func sectioned(_ trips: [Trip]) -> TripSections {
    let someday = trips
      .filter { $0.certaintyStage == .someday }
      .sorted { ($0.somedayRank, $0.name.lowercased()) < ($1.somedayRank, $1.name.lowercased()) }
    let targeted = trips
      .filter { $0.certaintyStage == .targeted }
      .sorted { lhs, rhs in
        let l = (lhs.targetYear ?? .max, lhs.targetQuarter?.rawValue ?? 0, lhs.name.lowercased())
        let r = (rhs.targetYear ?? .max, rhs.targetQuarter?.rawValue ?? 0, rhs.name.lowercased())
        return l < r
      }
    let dated = trips
      .filter { $0.certaintyStage == .dated }
      .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    return TripSections(someday: someday, targeted: targeted, dated: dated)
  }

  /// The in-play trips for the Ideas-screen capsules (the "launchpad"): every
  /// `dated` and `targeted` trip, plus the single top-of-backlog `someday` —
  /// derived from the certainty lifecycle, never filter MRU (which lingers
  /// stale). Ordered dated → targeted → someday, matching the sections.
  ///
  /// `Trip` carries no touch timestamp, so "most-recently-touched someday" is
  /// approximated by the top of the someday backlog (lowest `somedayRank`); when
  /// touch tracking exists this can sharpen without changing callers.
  public static func activeCapsules(_ trips: [Trip]) -> [Trip] {
    let sections = sectioned(trips)
    return sections.dated + sections.targeted + Array(sections.someday.prefix(1))
  }
}

extension Trip {
  /// The calendar date day `number` (1-based) lands on when the trip is dated;
  /// nil for undated trips. The itinerary is day-relative — this is derived for
  /// display only, never stored (docs/trip-time-model.md §2).
  public func date(forDay number: Int) -> Date? {
    guard let startDate else { return nil }
    return Calendar.current.date(byAdding: .day, value: number - 1, to: startDate)
  }

  /// The exact inverse of `date(forDay:)`: which day number `pinnedDate` lands on
  /// given `startDate` (docs/trip-time-model.md §4). Day 1 == `startDate`'s
  /// calendar day; whole-day difference, so a pinned reservation keeps its real
  /// date fixed and only its day-relative placement moves when `startDate` slides.
  /// Pure — no clamping to `1...lengthInDays`; a pin that lands before the trip
  /// starts or past its last day still gets its true day number here, the same
  /// way `TripIdea.itinerary` already clamps out-of-range day numbers for display.
  public static func dayNumber(forPinnedDate pinnedDate: Date, startDate: Date) -> Int {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: startDate)
    let pinned = calendar.startOfDay(for: pinnedDate)
    let days = calendar.dateComponents([.day], from: start, to: pinned).day ?? 0
    return days + 1
  }
}

/// Trips grouped by certainty stage, each section pre-sorted (see
/// `Trip.sectioned`).
public struct TripSections: Equatable, Sendable {
  public var someday: [Trip]
  public var targeted: [Trip]
  public var dated: [Trip]

  public init(someday: [Trip] = [], targeted: [Trip] = [], dated: [Trip] = []) {
    self.someday = someday
    self.targeted = targeted
    self.dated = dated
  }
}

extension TripIdea {
  /// Pull an idea onto a trip, or return the existing join if it's already
  /// there (idempotent — pulling twice doesn't duplicate). ADR-0004.
  @discardableResult
  public static func pull(
    ideaID: Idea.ID,
    into tripID: Trip.ID,
    status: TripIdeaStatus = .considering,
    in db: Database
  ) throws -> TripIdea {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    if let existing { return existing }
    let id = UUID()
    try TripIdea.insert {
      TripIdea.Draft(TripIdea(id: id, tripID: tripID, ideaID: ideaID, status: status))
    }
    .execute(db)
    guard let created = try TripIdea.find(id).fetchOne(db) else {
      throw TripError.creationFailed
    }
    return created
  }

  /// Creates another itinerary occurrence for an idea that is already on this
  /// trip. Pulling remains idempotent — the shortlist is still one deliberate
  /// membership decision — while this explicit operation models "eat here
  /// again" as a second stop with its own placement and ordering.
  @discardableResult
  public static func repeatScheduled(
    ideaID: Idea.ID,
    into tripID: Trip.ID,
    on schedule: Schedule,
    in db: Database
  ) throws -> TripIdea {
    guard schedule.dayNumber != nil else { throw TripError.invalidSchedule }
    let rank = try nextStopRank(tripID: tripID, in: db)
    let id = UUID()
    var occurrence = TripIdea(
      id: id,
      tripID: tripID,
      ideaID: ideaID,
      status: .scheduled,
      shortlistRank: rank,
      dayRank: Double(rank))
    occurrence.apply(schedule)
    try TripIdea.insert { TripIdea.Draft(occurrence) }.execute(db)
    guard let created = try TripIdea.find(id).fetchOne(db) else {
      throw TripError.creationFailed
    }
    return created
  }

  /// Advance (or retreat) an idea's lifecycle status on a trip. No-op if the
  /// idea isn't on the trip. Promoting *onto* the shortlist (from a status that
  /// wasn't on it) appends it to the bottom of the shortlist order; demoting
  /// leaves its rank untouched (harmless while off the shortlist).
  public static func setStatus(
    _ status: TripIdeaStatus,
    ideaID: Idea.ID,
    tripID: Trip.ID,
    in db: Database
  ) throws {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    guard let existing else { return }
    var rank = existing.shortlistRank
    if status.isOnShortlist, !existing.status.isOnShortlist {
      rank = try nextShortlistRank(tripID: tripID, in: db)
    }
    try TripIdea.find(existing.id)
      .update {
        $0.status = status
        $0.shortlistRank = rank
      }
      .execute(db)
  }

  /// Place a shortlisted idea onto a day (or re-place an already-scheduled one):
  /// set `status = .scheduled` and write the schedule columns in one update.
  /// No-op if the idea isn't on the trip.
  public static func schedule(
    _ schedule: Schedule,
    ideaID: Idea.ID,
    tripID: Trip.ID,
    in db: Database
  ) throws {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    // A nil day would violate the `.scheduled ⇔ dayNumber != nil` invariant —
    // callers wanting to clear a day use `unschedule` instead.
    guard let existing, schedule.dayNumber != nil else { return }
    try TripIdea.schedule(schedule, stopID: existing.id, in: db)
  }

  /// Commit a stop to the itinerary without a day yet — the "To Be Scheduled"
  /// bucket. Status becomes `.scheduled` with the day columns cleared; place it
  /// on a day later with `schedule(_:)`. No-op if the idea isn't on the trip.
  public static func scheduleUnplaced(ideaID: Idea.ID, tripID: Trip.ID, in db: Database) throws {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    guard let existing else { return }
    try scheduleUnplaced(stopID: existing.id, in: db)
  }

  /// Pull a scheduled stop back to the shortlist: clear its schedule columns and
  /// set `status = .shortlisted` (it keeps its `shortlistRank`). No-op if the
  /// idea isn't on the trip.
  public static func unschedule(ideaID: Idea.ID, tripID: Trip.ID, in db: Database) throws {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    guard let existing else { return }
    try unschedule(stopID: existing.id, in: db)
  }

  /// Mark a stop done after the trip and feed that back to the pool: flip the
  /// idea's `visited` flag in the same transaction (ADR-0004). No-op if the
  /// idea isn't on the trip.
  public static func markDone(ideaID: Idea.ID, tripID: Trip.ID, in db: Database) throws {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    guard let existing else { return }
    try markDone(stopID: existing.id, in: db)
  }

  /// Remove an idea from a trip entirely (back to the untouched pool).
  public static func remove(ideaID: Idea.ID, from tripID: Trip.ID, in db: Database) throws {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    guard let existing else { return }
    try remove(stopID: existing.id, in: db)
  }

  // MARK: - Stop-ID-keyed variants (ADR-0010: works for both idea-backed and freeform stops)

  /// Advance (or retreat) a stop's lifecycle status by its own primary key.
  public static func setStatus(_ status: TripIdeaStatus, stopID: TripIdea.ID, in db: Database) throws {
    switch status {
    case .skipped:
      try markSkipped(stopID: stopID, in: db)
      return
    case .done:
      try markDone(stopID: stopID, in: db)
      return
    case .considering, .shortlisted, .scheduled:
      break
    }
    guard let existing = try TripIdea.find(stopID).fetchOne(db) else { return }
    var rank = existing.shortlistRank
    if status.isOnShortlist, !existing.status.isOnShortlist {
      rank = try nextShortlistRank(tripID: existing.tripID, in: db)
    }
    try TripIdea.find(stopID)
      .update {
        $0.status = status
        $0.shortlistRank = rank
      }
      .execute(db)
  }

  /// Place a stop on a day by its own primary key.
  public static func schedule(_ schedule: Schedule, stopID: TripIdea.ID, in db: Database) throws {
    guard var entry = try TripIdea.find(stopID).fetchOne(db), schedule.dayNumber != nil else { return }
    entry.status = .scheduled
    entry.apply(schedule)
    try updateSharedSlot(
      members: alternativeMembers(containing: entry, in: db),
      status: entry.status,
      schedule: entry.schedule,
      in: db)
  }

  /// Commit a stop to the TBS bucket by its own primary key.
  public static func scheduleUnplaced(stopID: TripIdea.ID, in db: Database) throws {
    guard let entry = try TripIdea.find(stopID).fetchOne(db) else { return }
    try updateSharedSlot(
      members: alternativeMembers(containing: entry, in: db),
      status: .scheduled,
      schedule: .unscheduled,
      in: db)
  }

  /// Pull a stop back to the shortlist by its own primary key.
  public static func unschedule(stopID: TripIdea.ID, in db: Database) throws {
    guard let existing = try TripIdea.find(stopID).fetchOne(db) else { return }
    let members = try alternativeMembers(containing: existing, in: db)
    if existing.alternativeGroupID != nil {
      for member in members {
        try TripIdea.find(member.id)
          .update {
            $0.status = #bind(.shortlisted)
            $0.dayNumber = #bind(nil)
            $0.dayPart = #bind(nil)
            $0.startTime = #bind(nil)
            $0.endTime = #bind(nil)
            $0.alternativeGroupID = #bind(nil)
            $0.isActive = #bind(true)
          }
          .execute(db)
      }
      try reindexShortlist(tripID: existing.tripID, in: db)
      return
    }
    try TripIdea.find(stopID)
      .update {
        $0.status = #bind(.shortlisted)
        $0.dayNumber = #bind(nil)
        $0.dayPart = #bind(nil)
        $0.startTime = #bind(nil)
        $0.endTime = #bind(nil)
      }
      .execute(db)
  }

  /// Mark a stop done by its own primary key. For idea-backed stops also flips
  /// the pool idea's `visited` flag (ADR-0004); freeform stops have no pool idea.
  public static func markDone(stopID: TripIdea.ID, in db: Database) throws {
    guard let existing = try TripIdea.find(stopID).fetchOne(db) else { return }
    let members = try alternativeMembers(containing: existing, in: db)
    if existing.alternativeGroupID != nil {
      // Only the marked member leaves the ring, keeping its placement as history;
      // the remaining peers stay a scheduled ring-minus-one (a new effective active
      // reconciled below). This is symmetric with `markSkipped` and never empties
      // the slot when an inactive peer is the one marked done.
      try TripIdea.find(existing.id)
        .update {
          $0.status = #bind(.done)
          $0.alternativeGroupID = #bind(nil)
          $0.isActive = #bind(true)
        }
        .execute(db)
      try normalizeAlternativeMembers(members.filter { $0.id != existing.id }, in: db)
      if let ideaID = existing.ideaID {
        try Idea.find(ideaID).update { $0.visited = #bind(true) }.execute(db)
      }
      return
    }
    try TripIdea.find(stopID).update { $0.status = #bind(.done) }.execute(db)
    if let ideaID = existing.ideaID {
      try Idea.find(ideaID).update { $0.visited = #bind(true) }.execute(db)
    }
  }

  /// Delete a stop from the trip entirely by its own primary key.
  public static func remove(stopID: TripIdea.ID, in db: Database) throws {
    guard let existing = try TripIdea.find(stopID).fetchOne(db) else { return }
    let members = try alternativeMembers(containing: existing, in: db)
    try TripIdea.find(stopID).delete().execute(db)
    if existing.alternativeGroupID != nil {
      try normalizeAlternativeMembers(members.filter { $0.id != stopID }, in: db)
    }
  }

  /// Mark one alternative as skipped and retain the slot with its next peer.
  /// A skipped stop keeps its final placement as history but no longer belongs to
  /// the alternatives ring.
  public static func markSkipped(stopID: TripIdea.ID, in db: Database) throws {
    guard let existing = try TripIdea.find(stopID).fetchOne(db) else { return }
    let members = try alternativeMembers(containing: existing, in: db)
    if existing.alternativeGroupID != nil {
      try TripIdea.find(stopID)
        .update {
          $0.status = #bind(.skipped)
          $0.alternativeGroupID = #bind(nil)
          $0.isActive = #bind(true)
        }
        .execute(db)
      try normalizeAlternativeMembers(members.filter { $0.id != stopID }, in: db)
      return
    }
    try TripIdea.find(stopID).update { $0.status = #bind(.skipped) }.execute(db)
  }

  /// Join a shortlisted stop to a scheduled slot. The new peer receives the
  /// slot's shared placement but remains inactive until explicitly selected.
  public static func addAlternative(
    sourceStopID: TripIdea.ID,
    to targetStopID: TripIdea.ID,
    groupID: UUID = UUID(),
    in db: Database
  ) throws {
    guard
      var source = try TripIdea.find(sourceStopID).fetchOne(db),
      let target = try TripIdea.find(targetStopID).fetchOne(db),
      source.tripID == target.tripID,
      source.status == .shortlisted,
      target.status == .scheduled
    else { return }
    let destinationGroupID = target.alternativeGroupID ?? groupID
    if target.alternativeGroupID == nil {
      try TripIdea.find(target.id).update {
        $0.alternativeGroupID = #bind(destinationGroupID)
        $0.isActive = #bind(true)
      }.execute(db)
    }
    source.status = .scheduled
    source.shortlistRank = target.shortlistRank
    source.dayRank = target.dayRank
    source.alternativeGroupID = destinationGroupID
    source.isActive = false
    source.apply(target.schedule)
    try TripIdea.find(source.id)
      .update {
        $0.status = #bind(source.status)
        $0.shortlistRank = #bind(source.shortlistRank)
        $0.dayRank = #bind(source.dayRank)
        $0.dayNumber = #bind(source.dayNumber)
        $0.dayPart = #bind(source.dayPart)
        $0.startTime = #bind(source.startTime)
        $0.endTime = #bind(source.endTime)
        $0.alternativeGroupID = #bind(source.alternativeGroupID)
        $0.isActive = #bind(false)
      }
      .execute(db)
    try normalizeAlternativeMembers(
      try alternativeMembers(containing: source, in: db),
      in: db)
  }

  /// Create a freeform peer directly in an existing slot. It is born inactive,
  /// so the visible route does not change until the planner selects it.
  @discardableResult
  public static func addFreeformAlternative(
    title: String,
    note: String? = nil,
    to targetStopID: TripIdea.ID,
    groupID: UUID = UUID(),
    in db: Database
  ) throws -> TripIdea.ID? {
    guard let target = try TripIdea.find(targetStopID).fetchOne(db), target.status == .scheduled else {
      return nil
    }
    let destinationGroupID = target.alternativeGroupID ?? groupID
    if target.alternativeGroupID == nil {
      try TripIdea.find(target.id).update {
        $0.alternativeGroupID = #bind(destinationGroupID)
        $0.isActive = #bind(true)
      }.execute(db)
    }
    let id = UUID()
    let source = TripIdea(
      id: id,
      tripID: target.tripID,
      ideaID: nil,
      inlineTitle: title,
      inlineNote: note,
      status: .scheduled,
      shortlistRank: target.shortlistRank,
      dayRank: target.dayRank,
      alternativeGroupID: destinationGroupID,
      isActive: false,
      dayNumber: target.dayNumber,
      dayPart: target.dayPart,
      startTime: target.startTime,
      endTime: target.endTime)
    try TripIdea.insert { TripIdea.Draft(source) }.execute(db)
    try normalizeAlternativeMembers(try alternativeMembers(containing: source, in: db), in: db)
    return id
  }

  /// Select a particular peer and repair every stored activity flag in the ring.
  @discardableResult
  public static func setActiveAlternative(stopID: TripIdea.ID, in db: Database) throws -> TripIdea.ID? {
    guard let target = try TripIdea.find(stopID).fetchOne(db), target.alternativeGroupID != nil else {
      return nil
    }
    let members = try alternativeMembers(containing: target, in: db)
    guard members.count > 1 else {
      try normalizeAlternativeMembers(members, in: db)
      return members.first?.id
    }
    for member in members {
      try TripIdea.find(member.id).update { $0.isActive = #bind(member.id == target.id) }.execute(db)
    }
    return target.id
  }

  /// Advance from the effective member to the next peer in canonical ring order.
  @discardableResult
  public static func cycleAlternative(stopID: TripIdea.ID, in db: Database) throws -> TripIdea.ID? {
    guard let entry = try TripIdea.find(stopID).fetchOne(db), entry.alternativeGroupID != nil else {
      return nil
    }
    let members = try alternativeMembers(containing: entry, in: db)
    guard members.count > 1, let active = effectiveActiveMember(in: members),
      let index = members.firstIndex(where: { $0.id == active.id })
    else {
      try normalizeAlternativeMembers(members, in: db)
      return members.first?.id
    }
    let next = members[(index + 1) % members.count]
    return try setActiveAlternative(stopID: next.id, in: db)
  }

  /// Extract one peer into the next independent itinerary position. The affected
  /// day or TBS cohort is reindexed from its logical order, never by adding an
  /// arbitrary rank offset (ADR-0035).
  public static func promoteAlternative(stopID: TripIdea.ID, in db: Database) throws {
    guard let promoted = try TripIdea.find(stopID).fetchOne(db), promoted.alternativeGroupID != nil else {
      return
    }
    let members = try alternativeMembers(containing: promoted, in: db)
    guard members.count > 1, let formerActive = effectiveActiveMember(in: members) else { return }
    let before = try TripIdea.where { $0.tripID.eq(promoted.tripID) }.fetchAll(db)
    try TripIdea.find(stopID)
      .update {
        $0.alternativeGroupID = #bind(nil)
        $0.isActive = #bind(true)
      }
      .execute(db)
    let remaining = members.filter { $0.id != stopID }
    try normalizeAlternativeMembers(remaining, in: db)
    let after = try TripIdea.where { $0.tripID.eq(promoted.tripID) }.fetchAll(db)
    let remainingActive = effectiveActiveMember(in: remaining)
    if let day = promoted.dayNumber {
      let ordered = TripIdea.orderedDayStops(
        TripIdea.effectiveActiveEntries(before).filter { $0.status == .scheduled && $0.dayNumber == day })
      let ids = ordered.flatMap { entry -> [TripIdea.ID] in
        guard entry.id == formerActive.id else { return [entry.id] }
        return [remainingActive?.id, promoted.id].compactMap { $0 }
      }
      try reorderDayStops(ids, in: db)
    } else {
      let ordered = TripIdea.effectiveActiveEntries(before)
        .filter { $0.status == .scheduled && $0.dayNumber == nil }
        .sorted { ($0.shortlistRank, $0.id.uuidString) < ($1.shortlistRank, $1.id.uuidString) }
      let ids = ordered.flatMap { entry -> [TripIdea.ID] in
        guard entry.id == formerActive.id else { return [entry.id] }
        return [remainingActive?.id, promoted.id].compactMap { $0 }
      }
      for (rank, id) in ids.enumerated() {
        guard let entry = after.first(where: { $0.id == id }) else { continue }
        for member in try alternativeMembers(containing: entry, in: db) {
          try TripIdea.find(member.id).update { $0.shortlistRank = rank }.execute(db)
        }
      }
    }
  }

  // MARK: - Pinned reservations (docs/trip-time-model.md §4)

  /// Pin (or, with `nil`, un-pin) a stop's absolute reservation date and booking
  /// metadata. No-op if the stop doesn't exist. Pinning marks the stop
  /// `.scheduled` and, when the trip is already dated, immediately re-derives its
  /// `dayNumber` from the pin so the itinerary reflects the booking without
  /// waiting for a later `Trip.update` — on an undated trip the pin is stored
  /// inert (kept, and made effective once the trip is dated and `Trip.update`
  /// runs `rederivePinnedStops`). Un-pinning drops the pin/metadata but leaves the
  /// stop's current `dayNumber`/status alone — it becomes an ordinary day-relative
  /// stop sitting right where it was.
  public static func setBooking(_ pin: ReservationPin?, stopID: TripIdea.ID, in db: Database) throws {
    guard let existing = try TripIdea.find(stopID).fetchOne(db) else { return }
    let members = try alternativeMembers(containing: existing, in: db)
    let appliesToSlot = TripIdea.effectiveActiveMember(in: members)?.id == stopID
    let startDate = try Trip.find(existing.tripID).fetchOne(db)?.startDate
    let rederivedDay = pin.flatMap { p in startDate.map { Trip.dayNumber(forPinnedDate: p.date, startDate: $0) } }
    let dayNumber = appliesToSlot ? (rederivedDay ?? existing.dayNumber) : existing.dayNumber
    let status: TripIdeaStatus = pin != nil ? .scheduled : existing.status
    try TripIdea.find(stopID)
      .update {
        $0.pinnedDate = #bind(pin?.date)
        $0.confirmationNumber = #bind(pin?.confirmationNumber)
        $0.bookingURL = #bind(pin?.bookingURL)
        $0.partySize = #bind(pin?.partySize)
        $0.dayNumber = #bind(dayNumber)
        $0.status = #bind(status)
      }
      .execute(db)
    guard appliesToSlot else { return }
    let schedule = dayNumber.map { existing.schedule.onDay($0) } ?? .unscheduled
    try updateSharedSlot(members: members, status: status, schedule: schedule, in: db)
  }

  /// Re-derive `dayNumber` for every pinned stop on `tripID` after its `startDate`
  /// changes (docs/trip-time-model.md §4) — called from `Trip.update`. A pinned
  /// stop's `pinnedDate` never moves; only the day-relative `dayNumber` it implies
  /// shifts to keep landing on that same real date. Filtered in Swift (a trip
  /// carries a handful of stops), matching this file's other Swift-side filters.
  static func rederivePinnedStops(tripID: Trip.ID, startDate: Date, in db: Database) throws {
    let pinned = try TripIdea
      .where { $0.tripID.eq(tripID) }
      .fetchAll(db)
      .filter { $0.pinnedDate != nil }
    for entry in pinned {
      guard let pinnedDate = entry.pinnedDate else { continue }
      let day = Trip.dayNumber(forPinnedDate: pinnedDate, startDate: startDate)
      guard day != entry.dayNumber else { continue }
      let members = try alternativeMembers(containing: entry, in: db)
      guard effectiveActiveMember(in: members)?.id == entry.id else { continue }
      try updateSharedSlot(
        members: members,
        status: .scheduled,
        schedule: entry.schedule.onDay(day),
        in: db)
    }
  }

  // MARK: - Freeform stops (ADR-0010)

  /// Create a freeform stop (no pool idea) directly on the itinerary, born
  /// `.scheduled` in the To-Be-Scheduled bucket — place it on a day afterward
  /// with `schedule(_:stopID:)`. Appended to the bottom of the trip's intra-day
  /// order so it lands last, not jostling existing stops. Returns the new id.
  @discardableResult
  public static func createFreeform(
    tripID: Trip.ID,
    title: String,
    note: String? = nil,
    in db: Database
  ) throws -> TripIdea.ID {
    let id = UUID()
    let rank = try nextStopRank(tripID: tripID, in: db)
    try TripIdea.insert {
      TripIdea.Draft(
        TripIdea(
          id: id, tripID: tripID, ideaID: nil,
          inlineTitle: title, inlineNote: note,
          status: .scheduled, shortlistRank: rank
        )
      )
    }
    .execute(db)
    return id
  }

  /// Edit a freeform stop's inline content. No-op on an idea-backed stop (whose
  /// content lives in the pool idea, not here) or a missing stop. ADR-0010.
  public static func editFreeform(
    stopID: TripIdea.ID,
    title: String,
    note: String?,
    in db: Database
  ) throws {
    guard let existing = try TripIdea.find(stopID).fetchOne(db), existing.ideaID == nil else { return }
    try TripIdea.find(stopID)
      .update {
        $0.inlineTitle = #bind(title)
        $0.inlineNote = #bind(note)
      }
      .execute(db)
  }

  // MARK: - Pure partitioning (functional core)

  /// This trip's shortlist — entries that earned a place (shortlisted onward),
  /// in rank order. Pure.
  public static func shortlist(_ entries: [TripIdea]) -> [TripIdea] {
    entries
      .filter { $0.status.isOnShortlist }
      .sorted { $0.shortlistRank < $1.shortlistRank }
  }

  /// This trip's "considering" maybe-pile — pulled but not yet committed. Pure.
  public static func considering(_ entries: [TripIdea]) -> [TripIdea] {
    entries.filter { $0.status == .considering }
  }

  /// Scheduled stops not yet placed on a day — the "To Be Scheduled" bucket that
  /// sits atop the itinerary, in shortlist-rank order. Pure.
  public static func toBeScheduled(_ entries: [TripIdea]) -> [TripIdea] {
    effectiveActiveEntries(entries)
      .filter { $0.status == .scheduled && $0.dayNumber == nil }
      .sorted { $0.shortlistRank < $1.shortlistRank }
  }

  /// Lay the `scheduled` stops out across days 1…`lengthInDays`. Every day is
  /// present (empty days included, so the view can offer them as drop targets);
  /// each day's stops are ordered by `orderedDayStops` (ADR-0033). Stops whose day
  /// falls outside 1…`lengthInDays` (e.g. the trip was shortened) collapse onto the
  /// last day so nothing silently vanishes. Pure — the densely-tested core.
  public static func itinerary(_ entries: [TripIdea], lengthInDays: Int) -> [ItineraryDay] {
    let days = Swift.max(1, lengthInDays)
    let scheduled = effectiveActiveEntries(entries)
      .filter { $0.status == .scheduled && $0.dayNumber != nil }
    return (1...days).map { number in
      let stops = orderedDayStops(
        scheduled.filter { entry in
          let day = entry.dayNumber ?? 1
          return Swift.min(Swift.max(day, 1), days) == number
        })
      return ItineraryDay(number: number, stops: stops)
    }
  }

  /// Order one day's stops (ADR-0033). Timed and dayparted stops anchor by their
  /// clock/band position (`intraDaySort`), exactly as before. A bare `.day`
  /// "Anytime" stop is the floating case: rather than piling at the day's end, it
  /// **adopts the `intraDaySort` of the last timed/dayparted stop before it in
  /// manual `dayRank` order** — so dropping it after the 10:00 stop makes it sort
  /// after 10:00 and before 14:00. A deliberately moved pre-first Anytime stop
  /// carries a negative `dayRank` marker and takes the minute immediately before
  /// the first timed/dayparted anchor, so "Move Earlier" genuinely works at the
  /// start of the day without re-seating old untouched data.
  /// `dayRank` is the final tiebreak: it keeps stops that share an anchor (or an
  /// equal clock time) in the user's manual order. Pure — the densely-tested core.
  ///
  /// The anchor lives here, in the day builder, rather than inside
  /// `Schedule.intraDaySort`, so that `Schedule` stays a context-free value (it
  /// can't see its day's other stops). Refines ADR-0033 §2, which floated putting
  /// the anchor on `intraDaySort`.
  public static func orderedDayStops(_ stops: [TripIdea]) -> [TripIdea] {
    let key = effectiveIntraDaySort(stops)
    return stops.sorted { a, b in
      (key[a.id] ?? a.schedule.intraDaySort, a.dayRank)
        < (key[b.id] ?? b.schedule.intraDaySort, b.dayRank)
    }
  }

  /// The **effective** intra-day sort minute for each stop on a day (ADR-0033),
  /// keyed by stop ID: a stop's own `intraDaySort`, except a bare `.day` "Anytime"
  /// stop adopts its **anchor** — the `intraDaySort` of the most recent
  /// timed/dayparted stop before it in manual `dayRank` order (or, only when its
  /// rank is negative, the minute before the first timed/dayparted stop; otherwise
  /// end-of-day). Resolved in one `dayRank`-ordered pass, so an anchor always has a
  /// lower `dayRank` than the Anytime stop it anchors and the stop seats right after
  /// it. Shared by `orderedDayStops` and the timeline weave (`TripPlan.itineraryItems`)
  /// so a boundary row and an anchored Anytime stop interleave by the same key. Pure.
  public static func effectiveIntraDaySort(_ stops: [TripIdea]) -> [TripIdea.ID: Int] {
    var result: [TripIdea.ID: Int] = [:]
    var running: Int?
    let manuallyOrderedStops = stops.sorted(by: { $0.dayRank < $1.dayRank })
    let firstAnchor = manuallyOrderedStops.compactMap { stop -> Int? in
      switch stop.schedule {
      case .timed, .daypart: stop.schedule.intraDaySort
      case .day, .unscheduled: nil
      }
    }.first
    for stop in manuallyOrderedStops {
      switch stop.schedule {
      case .timed, .daypart:
        running = stop.schedule.intraDaySort
        result[stop.id] = stop.schedule.intraDaySort
      case .day:
        result[stop.id] = running ?? (stop.dayRank < 0 ? firstAnchor.map { $0 - 1 } : nil) ?? stop.schedule.intraDaySort
      case .unscheduled:
        result[stop.id] = stop.schedule.intraDaySort
      }
    }
    return result
  }
}

/// One day of a trip's itinerary: its 1-based number and the stops placed on it,
/// pre-ordered (see `TripIdea.itinerary`).
public struct ItineraryDay: Equatable, Identifiable, Sendable {
  public var number: Int
  public var stops: [TripIdea]
  public var id: Int { number }

  public init(number: Int, stops: [TripIdea] = []) {
    self.number = number
    self.stops = stops
  }
}

public enum TripError: Error {
  case creationFailed
  case invalidSchedule
}
