import Foundation

/// The **start-day solver** (ADR-0029 §4) — the documented payoff of the day-relative
/// itinerary (docs/trip-time-model.md §3). Because a stop keys off its **day number**
/// and `Trip.startDate` is a late-binding free variable, the start weekday can slide:
/// for each of the seven candidate start weekdays, map every keyed stop's day number to
/// the weekday it lands on and check that weekday against the stop's structured hours.
/// The canonical case — the destination restaurant you reach on day 6 is closed Mondays
/// (or does lunch only when you wanted dinner) — falls straight out.
///
/// The check is **meal-aware, not just open/closed** (§4): a *food* stop scheduled at a
/// time implies an intended meal (evening → dinner, midday → lunch), and a conflict is
/// raised when the hours are open that weekday but not *for that meal*. A stop with no
/// intended meal (a bare `.day`, or a non-food stop) falls back to plain open/closed.
///
/// Pure, no AI, no MapKit, no I/O — a functional-core value type, trivially testable.
/// `.unknown` hours never conflict (§1), so the solver degrades gracefully before hours
/// coverage is complete.
public enum StartDaySolver {
  /// Solve for every candidate start weekday, returning one option per weekday in
  /// Monday→Sunday order. The UI ranks by `conflicts.count` (see `StartDayOption`).
  public static func solve(stops: [SolverStop]) -> [StartDayOption] {
    Weekday.allCases.map { startWeekday in
      let conflicts = stops.flatMap { stop in
        conflict(for: stop, startWeekday: startWeekday).map { [$0] } ?? []
      }
      return StartDayOption(startWeekday: startWeekday, conflicts: conflicts)
    }
  }

  /// The single conflict a stop raises for a given start weekday, or `nil` when it's
  /// clean (open, or hours unknown, or no intended meal and simply not closed).
  private static func conflict(for stop: SolverStop, startWeekday: Weekday) -> HoursConflict? {
    guard let dayNumber = stop.schedule.dayNumber else { return nil }
    let weekday = startWeekday.adding(days: dayNumber - 1)

    if let meal = stop.intendedMeal {
      // Meal-aware: open, but not for the meal we wanted, is a conflict. `nil` (no
      // assertion — unknown, or open with no meal detail) never conflicts.
      if stop.weeklyHours.serves(meal, on: weekday) == false {
        return HoursConflict(
          stopID: stop.id, stopName: stop.name, dayNumber: dayNumber, weekday: weekday,
          reason: .notServingMeal(meal)
        )
      }
      return nil
    }

    // No intended meal → plain open/closed. Only an asserted `.closed` conflicts;
    // `.open` / `.unknown` don't.
    if stop.weeklyHours.isClosed(on: weekday) {
      return HoursConflict(
        stopID: stop.id, stopName: stop.name, dayNumber: dayNumber, weekday: weekday,
        reason: .closed
      )
    }
    return nil
  }
}

extension StartDaySolver {
  /// Build the keyed `SolverStop`s from a trip's stops and its ideas: every
  /// *scheduled, day-placed* stop that resolves to a pool idea carrying an asserted
  /// `WeeklyHours`. Freeform stops (no idea), unscheduled/undated stops, and stops with
  /// no structured hours are dropped — they simply don't constrain the start (§5's
  /// graceful degradation). Pure; the panel calls this over its read-models.
  public static func stops(entries: [TripIdea], ideasByID: [Idea.ID: Idea]) -> [SolverStop] {
    entries.compactMap { entry in
      guard entry.status == .scheduled, entry.dayNumber != nil,
        let ideaID = entry.ideaID, let idea = ideasByID[ideaID],
        let hours = idea.weeklyHours, hours.hasAnyAssertion
      else { return nil }
      return SolverStop(
        id: entry.id,
        name: idea.name,
        schedule: entry.schedule,
        weeklyHours: hours,
        servesMeals: idea.kind?.servesMeals ?? false
      )
    }
  }
}

/// One keyed stop fed to the solver: its identity, its day-relative placement, its
/// structured hours, and whether it's a food stop (only food stops imply a meal). A
/// "key" stop in v1 is any *scheduled* stop that carries structured hours; the app
/// builds these from the trip's itinerary + each stop's `Idea.weeklyHours`.
public struct SolverStop: Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var schedule: Schedule
  public var weeklyHours: WeeklyHours
  /// Whether this stop's kind takes meal service (a food stop). Drives whether the
  /// schedule implies an intended meal; a non-food stop is always checked plain
  /// open/closed, so a museum's Evening stop is never treated as "dinner" (§4).
  public var servesMeals: Bool

  public init(
    id: UUID,
    name: String,
    schedule: Schedule,
    weeklyHours: WeeklyHours,
    servesMeals: Bool
  ) {
    self.id = id
    self.name = name
    self.schedule = schedule
    self.weeklyHours = weeklyHours
    self.servesMeals = servesMeals
  }

  /// The meal this stop's schedule implies, or `nil` for a non-food stop or a bare
  /// `.day`/`.unscheduled` with no time-of-day (→ plain open/closed). The solver's
  /// only bridge from *scheduling* (`DayPart`/`Schedule`) to *meal service* (§4).
  public var intendedMeal: Meal? {
    guard servesMeals else { return nil }
    switch schedule {
    case .unscheduled, .day:
      return nil
    case let .daypart(_, part):
      return Self.meal(for: part)
    case let .timed(_, start, _):
      return Schedule.minutes(from: start).map(Meal.forClock(minute:))
    }
  }

  /// Map a coarse `DayPart` to the meal it implies (§4). Kept here — meal service is a
  /// property of a food stop, not of the scheduling primitive.
  private static func meal(for part: DayPart) -> Meal {
    switch part {
    case .earlyMorning, .breakfast, .morning: .breakfast
    case .lunch, .afternoon: .lunch
    case .dinner, .evening: .dinner
    case .lateNight, .overNight: .lateNight
    }
  }
}

/// One start weekday's verdict: the weekday and the conflicts it produces. Clean starts
/// have an empty `conflicts`; the UI ranks by `conflicts.count` ascending.
public struct StartDayOption: Equatable, Identifiable, Sendable {
  public var startWeekday: Weekday
  public var conflicts: [HoursConflict]
  public var id: Weekday { startWeekday }

  public init(startWeekday: Weekday, conflicts: [HoursConflict]) {
    self.startWeekday = startWeekday
    self.conflicts = conflicts
  }

  public var isClean: Bool { conflicts.isEmpty }
}

/// A single stop-on-a-weekday conflict the solver found for a candidate start.
public struct HoursConflict: Equatable, Identifiable, Sendable {
  /// Why this stop conflicts on this weekday.
  public enum Reason: Equatable, Sendable {
    /// The stop is closed that weekday (plain open/closed).
    case closed
    /// The stop is open that weekday but not serving the meal the schedule wanted.
    case notServingMeal(Meal)
  }

  public let stopID: UUID
  public var stopName: String
  public var dayNumber: DayNumber
  public var weekday: Weekday
  public var reason: Reason

  public var id: String { "\(stopID.uuidString)-\(dayNumber)" }

  public init(
    stopID: UUID,
    stopName: String,
    dayNumber: DayNumber,
    weekday: Weekday,
    reason: Reason
  ) {
    self.stopID = stopID
    self.stopName = stopName
    self.dayNumber = dayNumber
    self.weekday = weekday
    self.reason = reason
  }

  /// A short advisory phrase for the panel row, e.g. "Day 6 → Chez X: no dinner".
  public var detail: String {
    switch reason {
    case .closed: "Day \(dayNumber) → \(stopName): closed \(weekday.label)"
    case let .notServingMeal(meal): "Day \(dayNumber) → \(stopName): no \(meal.label.lowercased())"
    }
  }
}
