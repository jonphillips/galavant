import Foundation
import SQLiteData

/// One **stop** on a trip — usually a pulled pool idea, optionally a freeform
/// inline entry ("lunch break", "train to Aarhus") with no pool idea (ADR-0010).
/// The single real foreign key is to `Trip` (so the stop rides the trip and
/// cascade-deletes with it); `ideaID` is a loose, *optional* UUID, not a SQL FK,
/// per the single-FK sharing rule (ADR-0007) — orphans (idea deleted from the
/// pool) are reconciled on read, as with IdeaInterest. When `ideaID == nil` this
/// is a freeform stop and `inlineTitle`/`inlineNote` carry its content; the
/// read-model resolves the identity into a `StopContent` enum (ADR-0010).
/// `shortlistRank` orders the shortlist (V1's RankLists reborn as an ordering,
/// ADR-0004). Once `scheduled`, the stop is on the itinerary; its day-relative
/// placement lives in the four schedule columns behind the `Schedule` facade. A
/// `scheduled` stop with `dayNumber == nil` is committed to the trip but not yet
/// placed on a day — the "To Be Scheduled" bucket; a non-nil `dayNumber` places
/// it on that day. Freeform stops skip considering/shortlisted — they are born
/// `.scheduled` (ADR-0010).
@Table
public struct TripIdea: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var ideaID: Idea.ID?
  public var inlineTitle: String?
  public var inlineNote: String?
  public var status: TripIdeaStatus = .considering
  public var shortlistRank = 0
  /// Manual order **within a day** — the intra-day tiebreaker that lets an
  /// untimed ("Anytime") stop hold a position among timed stops instead of
  /// piling at the day's end by pool rank (ADR-0033). `Double` so an
  /// insert-between can take a neighbors' midpoint without renumbering. Distinct
  /// from `shortlistRank` (order in the shortlist *pile*); back-filled from it on
  /// migration so existing itineraries keep their order.
  public var dayRank: Double = 0
  public var dayNumber: Int?
  public var dayPart: DayPart?
  public var startTime: String?
  public var endTime: String?

  public init(
    id: UUID,
    tripID: Trip.ID,
    ideaID: Idea.ID?,
    inlineTitle: String? = nil,
    inlineNote: String? = nil,
    status: TripIdeaStatus = .considering,
    shortlistRank: Int = 0,
    dayRank: Double = 0,
    dayNumber: Int? = nil,
    dayPart: DayPart? = nil,
    startTime: String? = nil,
    endTime: String? = nil
  ) {
    self.id = id
    self.tripID = tripID
    self.ideaID = ideaID
    self.inlineTitle = inlineTitle
    self.inlineNote = inlineNote
    self.status = status
    self.shortlistRank = shortlistRank
    self.dayRank = dayRank
    self.dayNumber = dayNumber
    self.dayPart = dayPart
    self.startTime = startTime
    self.endTime = endTime
  }

  /// Make a freeform stop (no pool idea) on a trip, born `.scheduled` per
  /// ADR-0010. Placement is set afterward via `apply(_:)`.
  public static func freeform(
    id: UUID,
    tripID: Trip.ID,
    title: String,
    note: String? = nil,
    shortlistRank: Int = 0
  ) -> TripIdea {
    TripIdea(
      id: id,
      tripID: tripID,
      ideaID: nil,
      inlineTitle: title,
      inlineNote: note,
      status: .scheduled,
      shortlistRank: shortlistRank
    )
  }
}

extension TripIdea {
  /// This stop's day-relative placement as a domain value, rebuilt from columns.
  public var schedule: Schedule {
    Schedule(dayNumber: dayNumber, dayPart: dayPart, startTime: startTime, endTime: endTime)
  }

  /// Write a `Schedule` back into the flat columns, clearing the columns the
  /// chosen case doesn't use so storage never carries a stale time payload.
  public mutating func apply(_ schedule: Schedule) {
    switch schedule {
    case .unscheduled:
      (dayNumber, dayPart, startTime, endTime) = (nil, nil, nil, nil)
    case let .day(day):
      (dayNumber, dayPart, startTime, endTime) = (day, nil, nil, nil)
    case let .daypart(day, part):
      (dayNumber, dayPart, startTime, endTime) = (day, part, nil, nil)
    case let .timed(day, start, end):
      (dayNumber, dayPart, startTime, endTime) = (day, nil, start, end)
    }
  }
}

extension TripIdea.Draft {
  /// See `TripIdea.apply(_:)` — the same mapping for the draft.
  public mutating func apply(_ schedule: Schedule) {
    switch schedule {
    case .unscheduled:
      (dayNumber, dayPart, startTime, endTime) = (nil, nil, nil, nil)
    case let .day(day):
      (dayNumber, dayPart, startTime, endTime) = (day, nil, nil, nil)
    case let .daypart(day, part):
      (dayNumber, dayPart, startTime, endTime) = (day, part, nil, nil)
    case let .timed(day, start, end):
      (dayNumber, dayPart, startTime, endTime) = (day, nil, start, end)
    }
  }
}
