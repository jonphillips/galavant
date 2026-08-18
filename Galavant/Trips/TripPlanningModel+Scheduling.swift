import CoreLocation
import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// Scheduling, freeform-stop, accommodation (ADR-0011), and per-day region
/// (ADR-0012) write actions — the itinerary-mutating half of the planning model.
/// Split out of `TripPlanningModel` so the core file stays focused on state and the
/// derived read-model; the operations themselves live in the tested schema core.
extension TripPlanningModel {
  /// The local EventKit binding governs time edits on this device. The applied
  /// reservation cache is still in the synced trip row; Slice 3 supplies the
  /// shared review ledger and cross-device reconciliation identity.
  func calendarTimeAuthority(for stopID: TripIdea.ID) -> CalendarTimeAuthority {
    calendarLocalState.authority(for: stopID)
  }

  func reloadCalendarTimeAuthority() {
    calendarLocalState = calendarHistoryStore.state(tripID)
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

  /// Places a fresh occurrence of an already-scheduled idea. This deliberately
  /// does not turn `pull` into a duplicate-producing operation: the repeat is a
  /// user-authored itinerary fact, not a second shortlist membership.
  func placeRepeat(of stop: ResolvedStop, on day: Int?) {
    guard let day, let ideaID = stop.idea?.id else { return }
    _ = withErrorReporting {
      try database.write { db in
        try TripIdea.repeatScheduled(ideaID: ideaID, into: tripID, on: .day(day), in: db)
      }
    }
    destination = nil
  }

  /// Present the custom-stop editor to author a new freeform stop ("lunch",
  /// "train to Aarhus", "check in"). Defaults to the To-Be-Scheduled bucket; the
  /// sheet's day picker can land it on a day directly (ADR-0010).
  func addCustomStopButtonTapped() {
    destination = .freeformStop(FreeformStopDraft())
  }

  func addAlternativeButtonTapped(to stopID: TripIdea.ID) {
    destination = .alternativeSource(AlternativeSourceTarget(targetStopID: stopID))
  }

  func addAsAlternativeButtonTapped(sourceStopID: TripIdea.ID) {
    destination = .alternativeSlot(AlternativeSlotTarget(sourceStopID: sourceStopID))
  }

  func addCustomAlternativeButtonTapped(to targetStopID: TripIdea.ID) {
    destination = .freeformStop(FreeformStopDraft(alternativeToStopID: targetStopID))
  }

  func shortlistAlternativeSelected(_ sourceStopID: TripIdea.ID, for targetStopID: TripIdea.ID) {
    _ = withErrorReporting {
      try database.write { db in
        try TripIdea.addAlternative(sourceStopID: sourceStopID, to: targetStopID, in: db)
      }
    }
    destination = nil
  }

  func alternativeSlotSelected(_ targetStopID: TripIdea.ID, for sourceStopID: TripIdea.ID) {
    shortlistAlternativeSelected(sourceStopID, for: targetStopID)
  }

  func cycleAlternativeButtonTapped(_ stopID: TripIdea.ID) {
    var activeID: TripIdea.ID?
    _ = withErrorReporting {
      activeID = try database.write { db in
        try TripIdea.cycleAlternative(stopID: stopID, in: db)
      }
    }
    if let activeID { selectStop(activeID) }
  }

  func alternativeButtonTapped(_ stopID: TripIdea.ID) {
    _ = withErrorReporting {
      try database.write { db in
        try TripIdea.setActiveAlternative(stopID: stopID, in: db)
      }
    }
    selectStop(stopID)
  }

  func promoteAlternativeButtonTapped(_ stopID: TripIdea.ID) {
    _ = withErrorReporting {
      try database.write { db in
        try TripIdea.promoteAlternative(stopID: stopID, in: db)
      }
    }
    selectStop(stopID)
  }

  func toggleAlternativeDisclosure(_ groupID: UUID) {
    if expandedAlternativeGroupIDs.contains(groupID) {
      expandedAlternativeGroupIDs.remove(groupID)
    } else {
      expandedAlternativeGroupIDs.insert(groupID)
    }
  }

  func isAlternativeDisclosureExpanded(_ groupID: UUID) -> Bool {
    expandedAlternativeGroupIDs.contains(groupID)
  }

  func alternativesAreVisible(for ring: ResolvedAlternativeRing) -> Bool {
    isAlternativeDisclosureExpanded(ring.groupID) || canvasSelectedStopID == ring.activeMember.id
  }

  /// Re-open the editor seeded from an existing freeform stop. No-op on an
  /// idea-backed stop (those edit through the pool idea, not here).
  func editFreeform(_ stop: ResolvedStop) {
    guard case let .freeform(title, note, latitude, longitude) = stop.content else { return }
    destination = .freeformStop(
      FreeformStopDraft(
        stopID: stop.id,
        title: title,
        note: note ?? "",
        coordinate: latitude.flatMap { latitude in
          longitude.map { longitude in
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
          }
        },
        day: stop.entry.dayNumber))
  }

  /// Open the stop-note editor for any stop (idea-backed or freeform), seeded from
  /// its current `inlineNote` — the short "why it's here" caption on the itinerary.
  func editStopNote(_ stop: ResolvedStop) {
    destination = .stopNote(
      StopNoteDraft(
        stopID: stop.id,
        stopTitle: stop.content.title,
        note: stop.entry.inlineNote ?? ""))
  }

  /// Commit the stop-note editor. A blank note clears the caption.
  func saveStopNote(_ draft: StopNoteDraft) {
    withErrorReporting {
      try database.write { db in
        try TripIdea.setInlineNote(stopID: draft.stopID, note: draft.note, in: db)
      }
    }
    destination = nil
  }

  // MARK: - Stays (accommodations, ADR-0011)

  /// "Add lodging" — present the lodging editor for a new freeform stay. Defaults
  /// to nights 1→2; the sheet picks the span and (optionally) the hotel.
  func addLodgingButtonTapped() {
    let length = max(2, trip?.lengthInDays ?? 2)
    let maximumCheckIn = length - 1
    let earliestUncoveredDay = (1...maximumCheckIn).first {
      plan.stays(coveringDay: $0).isEmpty
    } ?? 1
    destination = .stay(StayDraft(
      checkInDay: earliestUncoveredDay,
      checkOutDay: earliestUncoveredDay + 1))
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
    if case let .freeform(t, n, _, _) = resolved.content {
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
          // A hotel is represented by its stay, not as an extra ordinary stop
          // in the shortlist/timeline. Keep the reusable pool idea intact.
          try TripIdea
            .where { $0.tripID.eq(tripID) && $0.ideaID.eq(ideaID) }
            .delete()
            .execute(db)
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

  /// Assign (or, with `nil`, clear) one of the trip's regions to a day (ADR-0012)
  /// — frames the day's empty map and labels it. Replaces any existing assignment
  /// for the day.
  func setDayRegion(_ regionID: MapRegion.ID?, forDay day: Int) {
    let tripID = tripID
    withErrorReporting {
      try database.write { db in
        try TripDayRegion.setRegion(regionID, forTrip: tripID, day: day, in: db)
      }
    }
  }

  /// The region currently assigned to a day, if any — drives the day-header menu's
  /// selection.
  func dayRegion(forDay day: Int) -> MapRegion? { plan.region(forDay: day) }

  func dayTimeZone(forDay day: Int) -> TimeZone? {
    allTripDayTimeZones.first {
      $0.tripID == tripID && $0.dayNumber == day
    }.flatMap { $0.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) }
  }

  func setDayTimeZone(_ identifier: String?, forDay day: Int) {
    let tripID = tripID
    withErrorReporting {
      try database.write { db in
        try TripDayTimeZone.set(identifier, forTrip: tripID, day: day, in: db)
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
    guard calendarTimeAuthority(for: stopID) == .manual else { return }
    withErrorReporting {
      try database.write { db in
        try TripIdea.schedule(schedule, stopID: stopID, in: db)
      }
    }
  }

  // MARK: - Stop clock-time editor (ADR-0033 Slice 4)

  /// Present the clock-time editor for a placed stop, pre-filled from
  /// `Schedule.suggestedTime` over the stop's ordered-day neighbors (ADR-0033 §3)
  /// — or, when the stop is already `.timed`, from its own start/end so a re-edit
  /// starts where it is. No-op for an unplaced stop (nothing to time). The write
  /// stays on the human tap: the sheet's Save calls `saveStopTime`.
  func editStopTime(_ stop: ResolvedStop) {
    guard calendarTimeAuthority(for: stop.id) == .manual else { return }
    let schedule = stop.entry.schedule
    guard let day = schedule.dayNumber else { return }
    let seededStart: String
    var seededEnd: String?
    if case let .timed(_, start, end) = schedule {
      seededStart = start
      seededEnd = end
    } else {
      let (previous, next) = bracketingSchedules(for: stop.id, onDay: day)
      seededStart = Schedule.suggestedTime(after: previous, before: next) ?? "12:00"
    }
    destination = .stopTime(
      StopTimeDraft(stopID: stop.id, day: day, start: seededStart, end: seededEnd))
  }

  /// Commit the clock-time editor: give the stop an exact `.timed` placement.
  func saveStopTime(_ draft: StopTimeDraft) {
    guard calendarTimeAuthority(for: draft.stopID) == .manual else { return }
    setSchedule(.timed(draft.day, start: draft.start, end: draft.end), for: draft.stopID)
    destination = nil
  }

  /// Drop a stop's clock time, returning it to a bare "Anytime" placement on the
  /// same day (the editor's "Remove Time" affordance — mirrors StopMenu's Anytime).
  func clearStopTime(_ draft: StopTimeDraft) {
    guard calendarTimeAuthority(for: draft.stopID) == .manual else { return }
    setSchedule(.day(draft.day), for: draft.stopID)
    destination = nil
  }

  // MARK: - Pinned reservations (docs/trip-time-model.md §4)

  /// Present the reservation-pin editor for a stop. Seeds from the stop's
  /// existing pin when it has one (editing); otherwise from its current day's
  /// calendar date on a dated trip, falling back to today — a reasonable first
  /// guess the human confirms or changes, never silently trusted.
  func editBooking(_ stop: ResolvedStop) {
    guard calendarTimeAuthority(for: stop.id) == .manual else { return }
    let entry = stop.entry
    let seededDate =
      entry.pinnedDate
      ?? entry.schedule.dayNumber.flatMap { trip?.date(forDay: $0) }
      ?? Date()
    destination = .booking(
      BookingDraft(
        stopID: stop.id,
        isEditing: entry.pinnedDate != nil,
        date: seededDate,
        confirmationNumber: entry.confirmationNumber ?? "",
        bookingURL: entry.bookingURL ?? "",
        partySize: entry.partySize.map(String.init) ?? ""
      ))
  }

  /// Commit the reservation-pin editor: nail the stop to `draft.date` (plus
  /// whatever booking metadata was entered — all optional, blank fields drop to
  /// `nil`). `TripIdea.setBooking` computes the resulting `dayNumber` when the
  /// trip is dated; on an undated trip the pin is stored inert.
  func saveBooking(_ draft: BookingDraft) {
    guard calendarTimeAuthority(for: draft.stopID) == .manual else { return }
    let confirmation = draft.confirmationNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = draft.bookingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let partySize = Int(draft.partySize.trimmingCharacters(in: .whitespacesAndNewlines))
    let pin = ReservationPin(
      date: draft.date,
      confirmationNumber: confirmation.isEmpty ? nil : confirmation,
      bookingURL: url.isEmpty ? nil : url,
      partySize: partySize
    )
    let stopID = draft.stopID
    withErrorReporting {
      try database.write { db in
        try TripIdea.setBooking(pin, stopID: stopID, in: db)
      }
    }
    destination = nil
  }

  /// Un-pin a stop's reservation (the editor's destructive "Remove Pin"),
  /// returning it to an ordinary day-relative stop sitting right where it was.
  func clearBooking(_ draft: BookingDraft) {
    guard calendarTimeAuthority(for: draft.stopID) == .manual else { return }
    let stopID = draft.stopID
    withErrorReporting {
      try database.write { db in
        try TripIdea.setBooking(nil, stopID: stopID, in: db)
      }
    }
    destination = nil
  }

  /// Move a stop to another day — StopMenu's Move-to-Day. A `.timed` stop seeds its
  /// clock time from the **destination** day's neighbors rather than carrying the
  /// old day's time blindly (ADR-0033 §3): it appends after that day's last timed
  /// stop, preserving its duration. Falls back to a straight day change (keeping
  /// granularity) for Anytime/dayparted stops, or when the new day has no timed
  /// stop to reason from.
  func moveToDay(_ stop: ResolvedStop, day: Int) {
    let schedule = stop.entry.schedule
    guard case let .timed(_, start, end) = schedule, day != schedule.dayNumber else {
      setSchedule(schedule.onDay(day), for: stop.id)
      return
    }
    let destTimed = orderedStops(onDay: day)
      .last { if case .timed = $0.entry.schedule { return true } else { return false } }
    guard let suggestion = Schedule.suggestedTime(after: destTimed?.entry.schedule, before: nil) else {
      setSchedule(schedule.onDay(day), for: stop.id)
      return
    }
    setSchedule(
      .timed(day, start: suggestion, end: Self.shiftedEnd(start: start, end: end, to: suggestion)),
      for: stop.id)
  }

  // MARK: - Non-drag intra-day reorder (ADR-0033 Slice 4)

  /// Whether the stop can move one slot earlier in its day. Only a bare `.day`
  /// "Anytime" stop carries a hand-order (`dayRank`), including ahead of the
  /// day's first timed/dayparted stop.
  func canMoveStopEarlier(_ stop: ResolvedStop) -> Bool { reorderedIDs(stop, earlier: true) != nil }

  /// Whether the stop can move one slot later in its day (see `canMoveStopEarlier`).
  func canMoveStopLater(_ stop: ResolvedStop) -> Bool { reorderedIDs(stop, earlier: false) != nil }

  /// Move a bare Anytime stop one slot earlier in its day, writing the day's new
  /// order to `dayRank` (ADR-0033). No-op when the move isn't expressible.
  func moveStopEarlier(_ stop: ResolvedStop) { reorderDay(stop, earlier: true) }

  /// Move a bare Anytime stop one slot later in its day (see `moveStopEarlier`).
  func moveStopLater(_ stop: ResolvedStop) { reorderDay(stop, earlier: false) }

  private func reorderDay(_ stop: ResolvedStop, earlier: Bool) {
    guard let ids = reorderedIDs(stop, earlier: earlier) else { return }
    guard let day = stop.entry.dayNumber else { return }
    let byID = Dictionary(uniqueKeysWithValues: orderedStops(onDay: day).map { ($0.id, $0) })
    let leadingAnytimeIDs = Set(ids.prefix { id in
      guard let entry = byID[id] else { return false }
      if case .day = entry.entry.schedule { return true }
      return false
    })
    withErrorReporting {
      try database.write { db in
        try TripIdea.reorderDayStops(ids, leadingAnytimeIDs: leadingAnytimeIDs, in: db)
      }
    }
  }

  /// The day's stop IDs after moving `stop` one slot in `earlier`/later direction,
  /// or nil when the move isn't expressible by order alone. Only bare `.day`
  /// stops reorder, including before the day's first timed/dayparted stop. Such
  /// explicitly-leading Anytime rows receive the core's negative-rank marker.
  private func reorderedIDs(_ stop: ResolvedStop, earlier: Bool) -> [TripIdea.ID]? {
    guard case .day = stop.entry.schedule, let day = stop.entry.schedule.dayNumber else { return nil }
    let stops = orderedStops(onDay: day)
    guard let from = stops.firstIndex(where: { $0.id == stop.id }) else { return nil }
    let to = earlier ? from - 1 : from + 1
    guard stops.indices.contains(to) else { return nil }
    var ids = stops.map(\.id)
    ids.remove(at: from)
    ids.insert(stop.id, at: to)
    return ids
  }

  // MARK: - Ordered-day helpers

  /// One day's stops in itinerary order (the pure `TripPlan` core does the
  /// ADR-0033 ordering); empty when the day has none.
  func orderedStops(onDay day: Int) -> [ResolvedStop] {
    plan.itinerary.first { $0.number == day }?.stops ?? []
  }

  /// The schedules of the stops bracketing `stopID` in its day's order — the two
  /// neighbors `Schedule.suggestedTime` reasons from. Nil on either side at a day
  /// edge or when the stop isn't found.
  private func bracketingSchedules(
    for stopID: TripIdea.ID, onDay day: Int
  ) -> (previous: Schedule?, next: Schedule?) {
    let stops = orderedStops(onDay: day)
    guard let i = stops.firstIndex(where: { $0.id == stopID }) else { return (nil, nil) }
    let previous = i > stops.startIndex ? stops[i - 1].entry.schedule : nil
    let next = i < stops.index(before: stops.endIndex) ? stops[i + 1].entry.schedule : nil
    return (previous, next)
  }

  /// A new `"HH:mm"` end that preserves an original `start…end` duration when the
  /// start shifts to `newStart` (cross-day seed). Nil when there was no end or a
  /// time won't parse — the stop keeps an open-ended `.timed`.
  private static func shiftedEnd(start: String, end: String?, to newStart: String) -> String? {
    guard let end,
          let startMin = clockMinutes(start),
          let endMin = clockMinutes(end),
          let newStartMin = clockMinutes(newStart)
    else { return nil }
    let shifted = min(newStartMin + max(0, endMin - startMin), 24 * 60 - 1)
    return String(format: "%02d:%02d", shifted / 60, shifted % 60)
  }

  /// Minutes-from-midnight for a `"HH:mm"` string; nil when malformed.
  private static func clockMinutes(_ hhmm: String) -> Int? {
    let parts = hhmm.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
    return hour * 60 + minute
  }

  // MARK: - Today execution (ADR-0039)

  /// Mark a scheduled stop done. The async write lets the live fetch refresh the
  /// plan after the operation without a second, manually-maintained state copy.
  func completeStop(_ stopID: TripIdea.ID) async {
    let now = date()
    await withErrorReporting {
      try await database.write { db in
        try TripIdea.complete(stopID: stopID, at: now, in: db)
      }
    }
  }

  /// Clear a stop's done outcome.
  func uncompleteStop(_ stopID: TripIdea.ID) async {
    await withErrorReporting {
      try await database.write { db in
        try TripIdea.uncomplete(stopID: stopID, in: db)
      }
    }
  }

  /// Mark a scheduled stop skipped.
  func skipStop(_ stopID: TripIdea.ID) async {
    let now = date()
    await withErrorReporting {
      try await database.write { db in
        try TripIdea.skip(stopID: stopID, at: now, in: db)
      }
    }
  }

  /// Clear a stop's skipped outcome.
  func unskipStop(_ stopID: TripIdea.ID) async {
    await withErrorReporting {
      try await database.write { db in
        try TripIdea.unskip(stopID: stopID, in: db)
      }
    }
  }

  /// Move a stop to the following itinerary day.
  func deferStopToTomorrow(_ stopID: TripIdea.ID) async {
    guard let day = allTripIdeas.first(where: { $0.id == stopID })?.dayNumber else { return }
    await withErrorReporting {
      try await database.write { db in
        try TripIdea.schedule(.day(day + 1), stopID: stopID, in: db)
      }
    }
  }

  /// Move a stop behind the current last stop on its day.
  func deferStopToLaterToday(_ stopID: TripIdea.ID) async {
    await withErrorReporting {
      try await database.write { db in
        try TripIdea.moveToEndOfDay(stopID: stopID, in: db)
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
