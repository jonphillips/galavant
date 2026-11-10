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
  public var rationaleVisit: String?
  public var rationaleWhy: String?
  public var rationaleFit: String?
  public var rationalePriority: Int?
  public var rationalePriorityOutOf: Int?
  /// Optional coordinates for a freeform stop. Both values are populated together
  /// by the custom-stop editor; a partial pair remains unlocated in the read model.
  public var inlineLatitude: Double?
  public var inlineLongitude: Double?
  /// Booking details supplied by a Calendar event linked to this stop. Kept
  /// separate from the user's idea/stop notes so reconciliation never overwrites
  /// planning text.
  public var calendarNotes: String?
  public var status: TripIdeaStatus = .considering
  public var shortlistRank = 0
  /// Manual order **within a day** — the intra-day tiebreaker that lets an
  /// untimed ("Anytime") stop hold a position among timed stops instead of
  /// piling at the day's end by pool rank (ADR-0033). `Double` so an
  /// insert-between can take a neighbors' midpoint without renumbering. Distinct
  /// from `shortlistRank` (order in the shortlist *pile*); back-filled from it on
  /// migration so existing itineraries keep their order.
  public var dayRank: Double = 0
  /// A loose link to the peer stops sharing this itinerary position. `nil` means
  /// this is an ordinary, independent stop (ADR-0035).
  public var alternativeGroupID: UUID?
  /// The stored choice in an alternatives ring. Concurrent writes can briefly
  /// leave a ring with zero or multiple `true` values; read projections choose a
  /// deterministic effective member and the next ring write repairs storage.
  public var isActive = true
  public var dayNumber: Int?
  public var dayPart: DayPart?
  public var startTime: String?
  public var endTime: String?
  /// The absolute calendar date this stop is nailed to, when it's a **confirmed
  /// reservation** (OpenTable, a hotel, a timed entry) rather than a day-relative
  /// planned stop (docs/trip-time-model.md §4). `nil` for every ordinary stop —
  /// the common case. When set, it sits *beside* `Schedule`, not inside it: the
  /// stop still carries a `dayNumber` for display/ordering, but that day number is
  /// re-derived from `pinnedDate` (via `Trip.dayNumber(forPinnedDate:startDate:)`)
  /// whenever the trip's start date changes, so the reservation keeps its real
  /// date instead of sliding with the trip. Inert on an undated trip (no
  /// `startDate` to re-derive against) until the trip becomes dated.
  public var pinnedDate: Date?
  public var bookingStatus: BookingStatus? = nil
  /// Booking metadata for a pinned reservation — free-form, never parsed.
  public var confirmationNumber: String?
  public var bookingURL: String?
  public var partySize: Int?
  /// Execution overlay (ADR-0039): when the traveler checked this stop off, on the
  /// day. `nil` for a stop not yet done. Mutually exclusive with `skippedAt`. The
  /// stop stays `.scheduled` — completion is a lens Today lays over the plan, not
  /// a status change.
  public var completedAt: Date?
  /// Execution overlay (ADR-0039): when the traveler skipped this stop ("not doing
  /// it"). Mutually exclusive with `completedAt`.
  public var skippedAt: Date?

  public init(
    id: UUID,
    tripID: Trip.ID,
    ideaID: Idea.ID?,
    inlineTitle: String? = nil,
    inlineNote: String? = nil,
    rationaleVisit: String? = nil,
    rationaleWhy: String? = nil,
    rationaleFit: String? = nil,
    rationalePriority: Int? = nil,
    rationalePriorityOutOf: Int? = nil,
    inlineLatitude: Double? = nil,
    inlineLongitude: Double? = nil,
    calendarNotes: String? = nil,
    status: TripIdeaStatus = .considering,
    shortlistRank: Int = 0,
    dayRank: Double = 0,
    alternativeGroupID: UUID? = nil,
    isActive: Bool = true,
    dayNumber: Int? = nil,
    dayPart: DayPart? = nil,
    startTime: String? = nil,
    endTime: String? = nil,
    pinnedDate: Date? = nil,
    bookingStatus: BookingStatus? = nil,
    confirmationNumber: String? = nil,
    bookingURL: String? = nil,
    partySize: Int? = nil,
    completedAt: Date? = nil,
    skippedAt: Date? = nil
  ) {
    self.id = id
    self.tripID = tripID
    self.ideaID = ideaID
    self.inlineTitle = inlineTitle
    self.inlineNote = inlineNote
    self.rationaleVisit = rationaleVisit
    self.rationaleWhy = rationaleWhy
    self.rationaleFit = rationaleFit
    self.rationalePriority = rationalePriority
    self.rationalePriorityOutOf = rationalePriorityOutOf
    self.inlineLatitude = inlineLatitude
    self.inlineLongitude = inlineLongitude
    self.calendarNotes = calendarNotes
    self.status = status
    self.shortlistRank = shortlistRank
    self.dayRank = dayRank
    self.alternativeGroupID = alternativeGroupID
    self.isActive = isActive
    self.dayNumber = dayNumber
    self.dayPart = dayPart
    self.startTime = startTime
    self.endTime = endTime
    self.pinnedDate = pinnedDate
    self.bookingStatus = bookingStatus
    self.confirmationNumber = confirmationNumber
    self.bookingURL = bookingURL
    self.partySize = partySize
    self.completedAt = completedAt
    self.skippedAt = skippedAt
  }

  /// Make a freeform stop (no pool idea) on a trip, born `.scheduled` per
  /// ADR-0010. Placement is set afterward via `apply(_:)`.
  public static func freeform(
    id: UUID,
    tripID: Trip.ID,
    title: String,
    note: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    shortlistRank: Int = 0
  ) -> TripIdea {
    TripIdea(
      id: id,
      tripID: tripID,
      ideaID: nil,
      inlineTitle: title,
      inlineNote: note,
      inlineLatitude: latitude,
      inlineLongitude: longitude,
      status: .scheduled,
      shortlistRank: shortlistRank
    )
  }
}

/// Total in-memory reading of the execution overlay (ADR-0039), mirroring how
/// `Schedule` faces flat columns. Writes keep the two dates mutually exclusive, so
/// `completedAt` wins if both are somehow set (repaired on the next write).
public enum StopOutcome: Equatable, Sendable {
  case pending
  case done(Date)
  case skipped
}

extension TripIdea {
  public var rationale: TripRationale {
    TripRationale(
      visit: rationaleVisit, why: rationaleWhy, fit: rationaleFit,
      priority: rationalePriority, priorityOutOf: rationalePriorityOutOf, note: inlineNote)
  }

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

  /// This stop's pinned-reservation fact, as a single value (docs/trip-time-model.md
  /// §4) — `nil` for an ordinary day-relative stop. Mirrors `Trip.headerImage`'s
  /// all-or-nothing fold of flat columns into one domain value; write through
  /// `TripIdea.setPinnedReservation(_:stopID:in:)`, not this property directly (the write
  /// needs the trip's `startDate` to re-derive `dayNumber`).
  public var booking: ReservationPin? {
    guard let pinnedDate else { return nil }
    return ReservationPin(date: pinnedDate)
  }

  public var outcome: StopOutcome {
    if let completedAt { return .done(completedAt) }
    if skippedAt != nil { return .skipped }
    return .pending
  }

  public var isPending: Bool { completedAt == nil && skippedAt == nil }
}

public struct TripRationale: Equatable, Sendable {
  public var visit: String?
  public var why: String?
  public var fit: String?
  public var priority: Int?
  public var priorityOutOf: Int?
  public var note: String?

  public init(
    visit: String?, why: String?, fit: String?, priority: Int? = nil,
    priorityOutOf: Int? = nil, note: String?
  ) {
    self.visit = visit
    self.why = why
    self.fit = fit
    self.priority = priority
    self.priorityOutOf = priorityOutOf
    self.note = note
  }

  public var isEmpty: Bool {
    priority == nil && priorityOutOf == nil
      && [visit, why, fit, note].allSatisfy { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
  }

  public var priorityLabel: String? {
    guard let priority else { return nil }
    return priorityOutOf.map { "#\(priority) of \($0)" } ?? "#\(priority)"
  }

  public func superseded(by incoming: TripRationale) -> TripRationale {
    let hasIncomingText = incoming.visit != nil || incoming.why != nil || incoming.fit != nil
    let hasIncomingPriority = incoming.priority != nil
    return TripRationale(
      visit: hasIncomingText ? incoming.visit : visit,
      why: hasIncomingText ? incoming.why : why,
      fit: hasIncomingText ? incoming.fit : fit,
      priority: hasIncomingPriority ? incoming.priority : priority,
      priorityOutOf: hasIncomingPriority ? incoming.priorityOutOf : priorityOutOf,
      note: note
    )
  }
}

public enum ChatRankMedal {
  public enum Tier: Hashable, Sendable {
    case gold
    case silver
    case bronze
  }

  public static func tier(priority: Int?, priorityOutOf: Int?) -> Tier? {
    guard priorityOutOf != 1 else { return nil }
    switch priority {
    case 1: return .gold
    case 2: return .silver
    case 3: return .bronze
    default: return nil
    }
  }

  public static func accessibilityLabel(priority: Int?, priorityOutOf: Int?) -> String? {
    guard tier(priority: priority, priorityOutOf: priorityOutOf) != nil, let priority else { return nil }
    let ordinal: String
    switch priority {
    case 1: ordinal = "first"
    case 2: ordinal = "second"
    case 3: ordinal = "third"
    default: return nil
    }
    if let priorityOutOf {
      return "Chat's \(ordinal) choice of \(priorityOutOf)"
    }
    return "Chat's \(ordinal) choice"
  }
}

/// A Chat rank attached to an open choice in one trip's planning context.
public struct ChatRank: Equatable, Sendable {
  public var priority: Int
  public var priorityOutOf: Int?

  public init(priority: Int, priorityOutOf: Int?) {
    self.priority = priority
    self.priorityOutOf = priorityOutOf
  }
}

extension TripIdea {
  /// The places still under consideration. Kept as the one predicate used by
  /// both the trip plan and other projections of the same maybe-pile.
  public static func isConsidering(_ entry: TripIdea) -> Bool {
    entry.status == .considering
  }

  /// Best medal-eligible rank for each idea among this trip's open choices.
  /// A stop is open while considering, or while it belongs to an alternatives ring.
  public static func openChoiceRanks(entries: [TripIdea]) -> [Idea.ID: ChatRank] {
    entries.reduce(into: [:]) { ranks, entry in
      guard let ideaID = entry.ideaID,
            isConsidering(entry) || entry.alternativeGroupID != nil,
            ChatRankMedal.tier(
              priority: entry.rationalePriority,
              priorityOutOf: entry.rationalePriorityOutOf) != nil,
            let priority = entry.rationalePriority
      else { return }

      let rank = ChatRank(priority: priority, priorityOutOf: entry.rationalePriorityOutOf)
      if let existing = ranks[ideaID], existing.priority <= rank.priority { return }
      ranks[ideaID] = rank
    }
  }
}

public enum TripRationaleBackfill {
  /// Return the rationale to write, or nil when history cannot safely reconstruct it.
  public static func update(
    for stop: TripIdea, from candidate: TripCandidate, priorityOutOf: Int? = nil
  ) -> TripRationale? {
    var visit = stop.rationaleVisit
    var why = stop.rationaleWhy
    var fit = stop.rationaleFit
    var note = stop.inlineNote
    var didUpdate = false

    if stop.rationaleVisit == nil, stop.rationaleWhy == nil, stop.rationaleFit == nil {
      let oldNote = stop.inlineNote?.trimmingCharacters(in: .whitespacesAndNewlines)
      let oldRationale = candidate.rationale?.trimmingCharacters(in: .whitespacesAndNewlines)
      if oldNote == oldRationale || (stop.inlineNote == nil && candidate.visit != nil) {
        visit = candidate.visit
        why = candidate.why
        fit = candidate.fit
        note = nil
        didUpdate = true
      }
    }

    var priority = stop.rationalePriority
    var savedPriorityOutOf = stop.rationalePriorityOutOf
    if priority == nil, let candidatePriority = candidate.priority {
      priority = candidatePriority
      savedPriorityOutOf = priorityOutOf
      didUpdate = true
    }

    guard didUpdate else { return nil }
    return TripRationale(
      visit: visit, why: why, fit: fit, priority: priority,
      priorityOutOf: savedPriorityOutOf, note: note)
  }
}

/// A confirmed reservation's absolute-date pin (docs/trip-time-model.md §4).
/// Booking details are stored separately through `setBookingDetails`.
public struct ReservationPin: Equatable, Sendable {
  public var date: Date

  public init(date: Date) {
    self.date = date
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
