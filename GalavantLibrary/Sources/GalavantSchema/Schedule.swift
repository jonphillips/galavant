import Foundation
import IssueReporting

public typealias DayNumber = Int

/// How precisely an itinerary stop is placed in time, as a single domain value
/// (STYLE §3) — the bar V2's `Schedule` set, adapted to V3's day-relative model
/// (docs/trip-time-model.md §2): stops key off a **day number**, never a stored
/// date, so the `.exact(Date…)` case is gone (the calendar view derives dates
/// from the trip's start). `TripIdea` stores this as flat columns; this enum is
/// the in-memory representation. Conversions are total in both directions
/// (mirrors `Certainty`).
public enum Schedule: Equatable, Sendable {
  /// Pulled but not placed on any day (a `shortlisted` row).
  case unscheduled
  /// On a day, no time of day chosen yet.
  case day(DayNumber)
  /// On a day, at a coarse time-of-day bucket.
  case daypart(DayNumber, DayPart)
  /// On a day, at clock times. `start`/`end` are `"HH:mm"` strings.
  case timed(DayNumber, start: String, end: String?)

  /// Which day (1…N) this stop sits on, or nil while unscheduled.
  public var dayNumber: DayNumber? {
    switch self {
    case .unscheduled: nil
    case let .day(day), let .daypart(day, _), let .timed(day, _, _): day
    }
  }

  public var dayPart: DayPart? {
    if case let .daypart(_, part) = self { part } else { nil }
  }

  /// Minutes-from-midnight key for ordering a single day's stops: clock times
  /// sort by their start, dayparts by their representative hour, a bare `.day`
  /// (and an `.unscheduled`, which never appears in a day) sort last. Ports
  /// V2's `startsAtIntraDaySort`.
  public var intraDaySort: Int {
    switch self {
    case let .timed(_, start, _):
      Self.minutes(from: start) ?? endOfDay
    case let .daypart(_, part):
      part.sortHour * 60
    case .day, .unscheduled:
      endOfDay
    }
  }

  /// A short label for the stop's time, for the itinerary row.
  public var display: String {
    switch self {
    case .unscheduled:
      "Unscheduled"
    case .day:
      "Anytime"
    case let .daypart(_, part):
      part.label
    case let .timed(_, start, end):
      end.map { "\(start)–\($0)" } ?? start
    }
  }

  /// Rebuild from the stored columns. Total: an impossible combination (a
  /// should-never-happen write) reports an issue and falls back to the
  /// best-supported case so the UI never sees a partial stop. A nil day means
  /// the stop isn't on the itinerary, so any time payload is discarded.
  public init(dayNumber: DayNumber?, dayPart: DayPart?, startTime: String?, endTime: String?) {
    guard let dayNumber else {
      self = .unscheduled
      return
    }
    if let startTime, !startTime.isEmpty {
      self = .timed(dayNumber, start: startTime, end: endTime)
    } else if let dayPart {
      self = .daypart(dayNumber, dayPart)
    } else {
      self = .day(dayNumber)
    }
  }

  /// This placement moved to a different day, keeping its time granularity
  /// (used when re-assigning a stop's day from the itinerary).
  public func onDay(_ day: DayNumber) -> Schedule {
    switch self {
    case .unscheduled, .day:
      .day(day)
    case let .daypart(_, part):
      .daypart(day, part)
    case let .timed(_, start, end):
      .timed(day, start: start, end: end)
    }
  }

  // MARK: - Suggested time (ADR-0033 §3)

  /// Default block length, in minutes, when only one neighbor is timed — how long
  /// a lone previous stop is assumed to run, and how far before a lone next stop to
  /// propose a start.
  public static let suggestedGapMinutes = 60

  /// A proposed `"HH:mm"` start for a stop being given a clock time on a day, from
  /// the timed stops that bracket its position (ADR-0033 §3). A **pure** function —
  /// it never writes; the caller seeds the time editor with it and the human
  /// confirms (ADR-0004/ADR-0030 keep the write on the tap). Two call sites:
  /// promoting an Anytime stop to timed, and moving a `.timed` stop to a new day.
  ///
  /// - `previous` end is its `end`, or its `start` + `suggestedGapMinutes` when it
  ///   has no end. `next` contributes its `start`.
  /// - both timed → start when the previous ends, unless that spills to/past the
  ///   next start, in which case the midpoint of the previous start and the next
  ///   start (so the suggestion always lands strictly between);
  /// - only a previous neighbor → right when it ends;
  /// - only a next neighbor → `suggestedGapMinutes` before it starts (clamped ≥ 0);
  /// - neither, or only non-timed/malformed neighbors → nil (nothing to reason
  ///   from; the editor stays blank).
  public static func suggestedTime(after previous: Schedule?, before next: Schedule?) -> String? {
    let prevStart = previous.flatMap(startMinutes)
    let prevEnd = previous.flatMap(endMinutes)
    let nextStart = next.flatMap(startMinutes)
    let minutes: Int
    switch (prevEnd, nextStart) {
    case let (prev?, next?):
      minutes = prev < next ? prev : ((prevStart ?? 0) + next) / 2
    case let (prev?, nil):
      minutes = prev
    case let (nil, next?):
      minutes = Swift.max(0, next - suggestedGapMinutes)
    case (nil, nil):
      return nil
    }
    return formatted(minutes: minutes)
  }

  /// A timed stop's start in minutes; nil for any other case or a malformed time.
  private static func startMinutes(_ schedule: Schedule) -> Int? {
    guard case let .timed(_, start, _) = schedule else { return nil }
    return minutes(from: start)
  }

  /// A timed stop's end in minutes — its `end`, or its `start + suggestedGapMinutes`
  /// when it has no end. Nil for any other case or a malformed time.
  private static func endMinutes(_ schedule: Schedule) -> Int? {
    guard case let .timed(_, start, end) = schedule else { return nil }
    if let end { return minutes(from: end) }
    return minutes(from: start).map { $0 + suggestedGapMinutes }
  }

  /// Render a minutes-from-midnight value as `"HH:mm"`, clamped to a single day.
  private static func formatted(minutes: Int) -> String {
    let clamped = Swift.min(Swift.max(minutes, 0), 24 * 60 - 1)
    return String(format: "%02d:%02d", clamped / 60, clamped % 60)
  }

  private var endOfDay: Int { 24 * 60 + 1 }

  /// Parse an `"HH:mm"` string into minutes from midnight. Reports an issue on
  /// a malformed value (callers fall back to end-of-day ordering).
  static func minutes(from time: String) -> Int? {
    let parts = time.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
      reportIssue("Malformed schedule time \"\(time)\"; sorting it to end of day")
      return nil
    }
    return hour * 60 + minute
  }
}
