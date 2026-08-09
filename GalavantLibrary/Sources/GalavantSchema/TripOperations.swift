import Foundation
import SQLiteData

extension Trip {
  /// Create a trip attached to the default travel party and return it. A new
  /// `someday` trip is appended to the bottom of the backlog regardless of the
  /// rank carried in `certainty` — the form never has to pick a position.
  public static func create(
    name: String,
    certainty: Certainty = .someday(rank: 0),
    lengthInDays: Int = 7,
    notes: String = "",
    in db: Database
  ) throws -> Trip {
    let partyID = try TravelParty.ensureDefault(in: db).id
    var certainty = certainty
    if certainty.stage == .someday {
      certainty = .someday(rank: try nextSomedayRank(in: db))
    }
    let id = UUID()
    var draft = Trip.Draft(
      id: id, name: name, notes: notes, lengthInDays: lengthInDays, travelPartyID: partyID
    )
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
      TripIdea.Draft(id: id, tripID: tripID, ideaID: ideaID, status: status)
    }
    .execute(db)
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
    guard var updated = existing, schedule.dayNumber != nil else { return }
    updated.status = .scheduled
    updated.apply(schedule)
    try TripIdea.find(updated.id)
      .update {
        $0.status = #bind(updated.status)
        $0.dayNumber = #bind(updated.dayNumber)
        $0.dayPart = #bind(updated.dayPart)
        $0.startTime = #bind(updated.startTime)
        $0.endTime = #bind(updated.endTime)
      }
      .execute(db)
  }

  /// Commit a stop to the itinerary without a day yet — the "To Be Scheduled"
  /// bucket. Status becomes `.scheduled` with the day columns cleared; place it
  /// on a day later with `schedule(_:)`. No-op if the idea isn't on the trip.
  public static func scheduleUnplaced(ideaID: Idea.ID, tripID: Trip.ID, in db: Database) throws {
    try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .update {
        $0.status = #bind(.scheduled)
        $0.dayNumber = #bind(nil)
        $0.dayPart = #bind(nil)
        $0.startTime = #bind(nil)
        $0.endTime = #bind(nil)
      }
      .execute(db)
  }

  /// Pull a scheduled stop back to the shortlist: clear its schedule columns and
  /// set `status = .shortlisted` (it keeps its `shortlistRank`). No-op if the
  /// idea isn't on the trip.
  public static func unschedule(ideaID: Idea.ID, tripID: Trip.ID, in db: Database) throws {
    try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .update {
        $0.status = #bind(.shortlisted)
        $0.dayNumber = #bind(nil)
        $0.dayPart = #bind(nil)
        $0.startTime = #bind(nil)
        $0.endTime = #bind(nil)
      }
      .execute(db)
  }

  /// Mark a stop done after the trip and feed that back to the pool: flip the
  /// idea's `visited` flag in the same transaction (ADR-0004). No-op if the
  /// idea isn't on the trip.
  public static func markDone(ideaID: Idea.ID, tripID: Trip.ID, in db: Database) throws {
    let existing = try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .fetchOne(db)
    guard let existing else { return }
    try TripIdea.find(existing.id).update { $0.status = #bind(.done) }.execute(db)
    try Idea.find(ideaID).update { $0.visited = #bind(true) }.execute(db)
  }

  /// Remove an idea from a trip entirely (back to the untouched pool).
  public static func remove(ideaID: Idea.ID, from tripID: Trip.ID, in db: Database) throws {
    try TripIdea
      .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
      .delete()
      .execute(db)
  }

  // MARK: - Stop-ID-keyed variants (ADR-0010: works for both idea-backed and freeform stops)

  /// Advance (or retreat) a stop's lifecycle status by its own primary key.
  public static func setStatus(_ status: TripIdeaStatus, stopID: TripIdea.ID, in db: Database) throws {
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
    try TripIdea.find(stopID)
      .update {
        $0.status = #bind(entry.status)
        $0.dayNumber = #bind(entry.dayNumber)
        $0.dayPart = #bind(entry.dayPart)
        $0.startTime = #bind(entry.startTime)
        $0.endTime = #bind(entry.endTime)
      }
      .execute(db)
  }

  /// Commit a stop to the TBS bucket by its own primary key.
  public static func scheduleUnplaced(stopID: TripIdea.ID, in db: Database) throws {
    try TripIdea.find(stopID)
      .update {
        $0.status = #bind(.scheduled)
        $0.dayNumber = #bind(nil)
        $0.dayPart = #bind(nil)
        $0.startTime = #bind(nil)
        $0.endTime = #bind(nil)
      }
      .execute(db)
  }

  /// Pull a stop back to the shortlist by its own primary key.
  public static func unschedule(stopID: TripIdea.ID, in db: Database) throws {
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
    try TripIdea.find(stopID).update { $0.status = #bind(.done) }.execute(db)
    if let ideaID = existing.ideaID {
      try Idea.find(ideaID).update { $0.visited = #bind(true) }.execute(db)
    }
  }

  /// Delete a stop from the trip entirely by its own primary key.
  public static func remove(stopID: TripIdea.ID, in db: Database) throws {
    try TripIdea.find(stopID).delete().execute(db)
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
    let startDate = try Trip.find(existing.tripID).fetchOne(db)?.startDate
    let rederivedDay = pin.flatMap { p in startDate.map { Trip.dayNumber(forPinnedDate: p.date, startDate: $0) } }
    let dayNumber = rederivedDay ?? existing.dayNumber
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
      try TripIdea.find(entry.id).update { $0.dayNumber = #bind(day) }.execute(db)
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
        id: id, tripID: tripID, ideaID: nil,
        inlineTitle: title, inlineNote: note,
        status: .scheduled, shortlistRank: rank)
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

  /// One past the bottom of this trip's intra-day order — max `shortlistRank`
  /// across *all* the trip's entries (not just shortlisted ones), where a fresh
  /// freeform stop appends. Distinct from `nextShortlistRank`, which scopes to
  /// the shortlist pile.
  static func nextStopRank(tripID: Trip.ID, in db: Database) throws -> Int {
    let ranks = try TripIdea
      .where { $0.tripID.eq(tripID) }
      .fetchAll(db)
      .map(\.shortlistRank)
    return (ranks.max() ?? -1) + 1
  }

  /// One past the current bottom of this trip's shortlist (0 when empty).
  static func nextShortlistRank(tripID: Trip.ID, in db: Database) throws -> Int {
    let ranks = try TripIdea
      .where { $0.tripID.eq(tripID) }
      .fetchAll(db)
      .filter { $0.status.isOnShortlist }
      .map(\.shortlistRank)
    return (ranks.max() ?? -1) + 1
  }

  /// Persist a new shortlist order: each entry's `shortlistRank` becomes its
  /// index in `orderedIDs` (TripIdea ids). Call after a drag-to-reorder.
  public static func reorderShortlist(_ orderedIDs: [TripIdea.ID], in db: Database) throws {
    for (index, id) in orderedIDs.enumerated() {
      try TripIdea.find(id).update { $0.shortlistRank = index }.execute(db)
    }
  }

  /// Persist a new intra-day order (ADR-0033): each stop's `dayRank` becomes its
  /// index in `orderedIDs` — the day's stops top to bottom as the user dragged
  /// them. Call after a drag-to-reorder within a single day. Distinct from
  /// `reorderShortlist`, which orders the shortlist pile; this orders one day's
  /// stops, letting an untimed stop sit between timed ones.
  public static func reorderDayStops(_ orderedIDs: [TripIdea.ID], in db: Database) throws {
    for (index, id) in orderedIDs.enumerated() {
      try TripIdea.find(id).update { $0.dayRank = Double(index) }.execute(db)
    }
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
    entries
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
    let scheduled = entries.filter { $0.status == .scheduled && $0.dayNumber != nil }
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
  /// after 10:00 and before 14:00. An Anytime stop with no timed/dayparted stop
  /// before it keeps end-of-day (today's behavior — nothing regresses for stops the
  /// user never positions; give it a daypart or time to anchor it earlier).
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
  /// timed/dayparted stop before it in manual `dayRank` order (end-of-day when none
  /// precedes it). Resolved in one `dayRank`-ordered pass, so an anchor always has a
  /// lower `dayRank` than the Anytime stop it anchors and the stop seats right after
  /// it. Shared by `orderedDayStops` and the timeline weave (`TripPlan.itineraryItems`)
  /// so a boundary row and an anchored Anytime stop interleave by the same key. Pure.
  public static func effectiveIntraDaySort(_ stops: [TripIdea]) -> [TripIdea.ID: Int] {
    var result: [TripIdea.ID: Int] = [:]
    var running: Int?
    for stop in stops.sorted(by: { $0.dayRank < $1.dayRank }) {
      switch stop.schedule {
      case .timed, .daypart:
        running = stop.schedule.intraDaySort
        result[stop.id] = stop.schedule.intraDaySort
      case .day:
        result[stop.id] = running ?? stop.schedule.intraDaySort  // anchor, else end-of-day
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
}
