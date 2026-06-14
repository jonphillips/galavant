import Foundation
import SQLiteData

/// One idea pulled onto one trip, carrying its lifecycle `status` (ADR-0004).
/// The single real foreign key is to `Trip` (so the join rides the trip and
/// cascade-deletes with it); `ideaID` is a loose UUID, not a SQL FK, per the
/// single-FK sharing rule (ADR-0007) — orphans (idea deleted from the pool) are
/// reconciled on read, as with IdeaInterest. `shortlistRank` orders the
/// shortlist (V1's RankLists reborn as an ordering, ADR-0004). Once `scheduled`,
/// the stop is on the itinerary; its day-relative placement lives in the four
/// schedule columns behind the `Schedule` facade. A `scheduled` stop with
/// `dayNumber == nil` is committed to the trip but not yet placed on a day — the
/// "To Be Scheduled" bucket; a non-nil `dayNumber` places it on that day.
@Table
public struct TripIdea: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var ideaID: Idea.ID
  public var status: TripIdeaStatus = .considering
  public var shortlistRank = 0
  public var dayNumber: Int?
  public var dayPart: DayPart?
  public var startTime: String?
  public var endTime: String?

  public init(
    id: UUID,
    tripID: Trip.ID,
    ideaID: Idea.ID,
    status: TripIdeaStatus = .considering,
    shortlistRank: Int = 0,
    dayNumber: Int? = nil,
    dayPart: DayPart? = nil,
    startTime: String? = nil,
    endTime: String? = nil
  ) {
    self.id = id
    self.tripID = tripID
    self.ideaID = ideaID
    self.status = status
    self.shortlistRank = shortlistRank
    self.dayNumber = dayNumber
    self.dayPart = dayPart
    self.startTime = startTime
    self.endTime = endTime
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
