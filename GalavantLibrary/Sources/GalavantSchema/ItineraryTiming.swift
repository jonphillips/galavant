import Foundation

/// The clock behind one day's woven timeline rows.
///
/// A day's `ItineraryItem` stream mixes stops, stay boundaries, calendar
/// constraints and travel connectors. Three separate questions — where the "now"
/// marker belongs, what is still ahead of you, and what Today calls *next* — are
/// all the same question: *when does this row happen?* They read it from here so
/// they can't disagree. They used to: the marker scanned stops only (so it sorted
/// below a future check-in), and Today's `next` only ever looked at stops (so a
/// check-in 75 minutes away left the day reading "clear").
///
/// Pure: minutes in, dates out. No clock, no I/O.
public struct ItineraryTiming: Equatable, Sendable {
  public var dayNumber: Int
  public var tripStartDate: Date
  /// ADR-0033 effective intra-day minutes, keyed by stop. An Anytime stop borrows
  /// its anchor's minute here exactly as the weave sorts it, so "is this still
  /// ahead of me?" is answered at the position the row is actually drawn at
  /// rather than by inventing a clock time the stop does not have.
  public var effectiveStopMinutes: [TripIdea.ID: Int]

  public init(dayNumber: Int, tripStartDate: Date, stops: [TripIdea]) {
    self.dayNumber = dayNumber
    self.tripStartDate = tripStartDate
    self.effectiveStopMinutes = TripIdea.effectiveIntraDaySort(stops)
  }

  /// The timing of an already-woven day. Derived from the stream itself rather
  /// than from the plan, which rebuilds its whole join graph on every access — a
  /// caller holding the day's rows must not pay for a second one.
  public init(dayNumber: Int, tripStartDate: Date, items: [ItineraryItem]) {
    self.init(
      dayNumber: dayNumber,
      tripStartDate: tripStartDate,
      stops: items.compactMap { item in
        guard case let .stop(stop) = item else { return nil }
        return stop.entry
      })
  }

  /// The event time of `items[index]`, or nil when the row carries no clock at
  /// all (a home-base row, the marker itself, a connector with no dated
  /// neighbour).
  ///
  /// A connector belongs to the event it **arrives at**: the directions between a
  /// finished lunch and a 15:00 check-in are 15:00's business, not the lunch's.
  /// It falls back to the row it departs for the day's trailing return leg, whose
  /// arrival — the lodging you sleep at — is not itself a row.
  public func nominalDate(at index: Int, in items: [ItineraryItem]) -> Date? {
    guard items.indices.contains(index) else { return nil }
    guard case .connector = items[index] else {
      return minutes(of: items[index]).flatMap(date(minutes:))
    }
    let arrival = eventIndex(from: items.index(after: index), by: 1, in: items)
    let departure = eventIndex(from: items.index(before: index), by: -1, in: items)
    return (arrival ?? departure).flatMap { minutes(of: items[$0]) }.flatMap(date(minutes:))
  }

  /// Index in `items` at which the "now" marker belongs: before the first row
  /// whose time is still ahead of `now`, whatever kind of row that is, or
  /// `items.count` when every dated row is past. Nil when the day has no dated
  /// row to sit the marker against at all.
  public func nowMarkerIndex(in items: [ItineraryItem], now: Date) -> Int? {
    let dates = items.indices.map { nominalDate(at: $0, in: items) }
    guard dates.contains(where: { $0 != nil }) else { return nil }
    return dates.firstIndex { $0.map { $0 > now } ?? false } ?? items.count
  }

  /// The minutes-from-midnight a non-connector row sits at — the same key the
  /// timeline weave sorts by, so timing and order can't drift apart.
  private func minutes(of item: ItineraryItem) -> Int? {
    switch item {
    case let .stop(stop):
      effectiveStopMinutes[stop.id] ?? stop.entry.schedule.intraDaySort
    case let .checkIn(stay):
      stay.stay.checkInSortMinutes
    case let .checkOut(stay):
      stay.stay.checkOutSortMinutes
    case let .calendarConstraint(constraint):
      constraint.intraDaySortMinutes
    case .connector, .nowMarker, .homeBase:
      nil
    }
  }

  private func date(minutes: Int) -> Date? {
    let calendar = Calendar.current
    guard let start = dayStart(
      dayNumber: dayNumber, tripStartDate: tripStartDate, calendar: calendar)
    else { return nil }
    return calendar.date(byAdding: .minute, value: minutes, to: start)
  }

  /// The nearest row in `direction` that is an event in its own right —
  /// connectors and the marker carry no time of their own, so they are stepped
  /// over rather than consulted.
  private func eventIndex(from start: Int, by direction: Int, in items: [ItineraryItem]) -> Int? {
    var index = start
    while items.indices.contains(index) {
      switch items[index] {
      case .connector, .nowMarker: index += direction
      default: return index
      }
    }
    return nil
  }
}

/// The start of the calendar day a 1-based trip day falls on.
func dayStart(dayNumber: Int, tripStartDate: Date, calendar: Calendar) -> Date? {
  guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: tripStartDate) else {
    return nil
  }
  return calendar.startOfDay(for: date)
}

/// A `HH:mm` clock time on a 1-based trip day.
func date(
  dayNumber: Int, time: String, tripStartDate: Date, calendar: Calendar
) -> Date? {
  guard let dayStart = dayStart(dayNumber: dayNumber, tripStartDate: tripStartDate, calendar: calendar),
    let minutes = Schedule.minutes(from: time)
  else { return nil }
  return calendar.date(byAdding: .minute, value: minutes, to: dayStart)
}
