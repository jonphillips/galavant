import Dependencies
import Foundation
import GalavantSchema

/// Scheduling, freeform-stop, accommodation (ADR-0011), and per-day region
/// (ADR-0012) write actions — the itinerary-mutating half of the planning model.
/// Split out of `TripPlanningModel` so the core file stays focused on state and the
/// derived read-model; the operations themselves live in the tested schema core.
extension TripPlanningModel {
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
