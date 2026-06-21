import Foundation
import SQLiteData

/// One **stay** on a trip — an accommodation that spans nights rather than sitting
/// at a point in time (ADR-0011). A stay is *not* a `TripIdea` and *not* a
/// `Schedule` case: it occupies a range (check-in day → check-out day), recurs as a
/// home-base anchor on every covered day, and has no single `intraDaySort` /
/// `nominalDate` position. So it gets its own sibling record instead of polluting
/// the point-in-time `Schedule` facade.
///
/// The single real foreign key is to `Trip` (the stay rides the trip and
/// cascade-deletes with it); `ideaID` is a loose, *optional* UUID, not a SQL FK,
/// per the single-FK sharing rule (ADR-0007) — orphans (the pool hotel deleted)
/// are reconciled on read, as with `TripIdea`. When `ideaID == nil` this is a
/// freeform stay (an unsaved Airbnb, "staying with friends") and
/// `inlineTitle`/`inlineNote` carry its content; the read-model resolves the
/// identity into the same `StopContent` enum a stop uses (ADR-0010), so a
/// freeform/unlocated stay carries no coordinate and falls out of the canvas for
/// free.
///
/// `checkInDay` is required at creation (1…N); `checkOutDay` must be `> checkInDay`
/// (validated by the write path). `checkInTime`/`checkOutTime` are optional
/// `"HH:mm"` strings (Schedule's convention) — absent a time, the check-in row
/// sorts to evening and the check-out row to morning.
///
/// *Seam for trip-time-model §4 (NOT this slice):* `pinnedDate` / confirmation # /
/// booking URL / booked-vs-planned land when capture or an import actually creates
/// a booking.
@Table
public struct TripStay: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var ideaID: Idea.ID?
  public var inlineTitle: String?
  public var inlineNote: String?
  public var checkInDay: Int = 1
  public var checkOutDay: Int = 2
  public var checkInTime: String?
  public var checkOutTime: String?

  public init(
    id: UUID,
    tripID: Trip.ID,
    ideaID: Idea.ID?,
    inlineTitle: String? = nil,
    inlineNote: String? = nil,
    checkInDay: Int = 1,
    checkOutDay: Int = 2,
    checkInTime: String? = nil,
    checkOutTime: String? = nil
  ) {
    self.id = id
    self.tripID = tripID
    self.ideaID = ideaID
    self.inlineTitle = inlineTitle
    self.inlineNote = inlineNote
    self.checkInDay = checkInDay
    self.checkOutDay = checkOutDay
    self.checkInTime = checkInTime
    self.checkOutTime = checkOutTime
  }

  /// Make a freeform stay (no pool idea) on a trip — a name + nights with no pool
  /// hotel, mirroring `TripIdea.freeform`. The write path validates the days.
  public static func freeform(
    id: UUID,
    tripID: Trip.ID,
    title: String,
    note: String? = nil,
    checkInDay: Int,
    checkOutDay: Int,
    checkInTime: String? = nil,
    checkOutTime: String? = nil
  ) -> TripStay {
    TripStay(
      id: id,
      tripID: tripID,
      ideaID: nil,
      inlineTitle: title,
      inlineNote: note,
      checkInDay: checkInDay,
      checkOutDay: checkOutDay,
      checkInTime: checkInTime,
      checkOutTime: checkOutTime
    )
  }
}

extension TripStay {
  /// The nights this stay covers — `checkInDay ..< checkOutDay` (you sleep the
  /// night of check-in through the night before check-out). Used for overlap
  /// detection (two stays clash when they share a night).
  public var nights: Range<Int> {
    checkInDay ..< Swift.max(checkInDay + 1, checkOutDay)
  }

  /// True when `day` falls inside the stay's span (check-in through check-out,
  /// inclusive) — the days that show the home-base chip.
  public func covers(day: Int) -> Bool {
    day >= checkInDay && day <= checkOutDay
  }

  /// Minutes-from-midnight key for ordering the check-in row among a day's stops.
  /// Uses `checkInTime` when set, else a late-evening default so an untimed
  /// check-in trails the day's activities. (Default deliberately tunable — Jon
  /// will live with the visuals; ADR-0011.)
  public var checkInSortMinutes: Int {
    checkInTime.flatMap(Schedule.minutes(from:)) ?? Self.defaultCheckInMinutes
  }

  /// Minutes-from-midnight key for ordering the check-out row among a day's stops.
  /// Uses `checkOutTime` when set, else an early-morning default so an untimed
  /// check-out leads the day.
  public var checkOutSortMinutes: Int {
    checkOutTime.flatMap(Schedule.minutes(from:)) ?? Self.defaultCheckOutMinutes
  }

  /// Default ordering anchors when no clock time is given. Centralized so Jon can
  /// tune both in one place against the live itinerary.
  static let defaultCheckInMinutes = 18 * 60   // 18:00 — evening
  static let defaultCheckOutMinutes = 10 * 60  // 10:00 — morning

  // MARK: - Overlap (pure)

  /// The set of stays that share at least one night with another stay — advisory
  /// only (changing hotels mid-trip, or a data slip), never blocked (ADR-0011 §6).
  /// Pure over the stays array; mirrors the gap-conflict family.
  public static func overlapping(_ stays: [TripStay]) -> Set<TripStay.ID> {
    var flagged: Set<TripStay.ID> = []
    for i in stays.indices {
      for j in stays.indices where j > i {
        if stays[i].nights.overlaps(stays[j].nights) {
          flagged.insert(stays[i].id)
          flagged.insert(stays[j].id)
        }
      }
    }
    return flagged
  }
}
