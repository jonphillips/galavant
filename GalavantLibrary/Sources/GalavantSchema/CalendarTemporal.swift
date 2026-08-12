import Foundation

/// A calendar date with no time or time zone. EventKit returns all-day values as
/// `Date`s in the device's default zone; this value is the semantic fact recovered
/// at that I/O boundary so later device-zone changes cannot move the day.
public struct CalendarCivilDate: Codable, Equatable, Hashable, Sendable, Comparable {
  public let year: Int
  public let month: Int
  public let day: Int

  public init?(year: Int, month: Int, day: Int) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(
      calendar: calendar, timeZone: calendar.timeZone,
      year: year, month: month, day: day)
    guard let date = calendar.date(from: components) else { return nil }
    let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
    guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
    self.year = year
    self.month = month
    self.day = day
  }

  public init(_ date: Date, calendar: Calendar) {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    self.year = components.year!
    self.month = components.month!
    self.day = components.day!
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }

  public func date(in timeZone: TimeZone) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day))
  }

  public func dayNumber(since start: Self) -> Int? {
    let utc = TimeZone(secondsFromGMT: 0)!
    guard let startDate = start.date(in: utc), let date = date(in: utc) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.dateComponents([.day], from: startDate, to: date).day.map { $0 + 1 }
  }

  public func adding(days: Int) -> Self? {
    let utc = TimeZone(secondsFromGMT: 0)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    guard let date = date(in: utc),
      let result = calendar.date(byAdding: .day, value: days, to: date)
    else { return nil }
    return Self(result, calendar: calendar)
  }

  var stableDescription: String {
    String(format: "%04d-%02d-%02d", year, month, day)
  }
}

/// A wall-clock date and time with deliberately no time zone. This is EventKit's
/// floating-event meaning: "lunch at noon" remains noon wherever it is observed.
public struct CalendarCivilDateTime: Codable, Equatable, Hashable, Sendable, Comparable {
  public let date: CalendarCivilDate
  public let hour: Int
  public let minute: Int
  public let second: Int

  public init?(date: CalendarCivilDate, hour: Int, minute: Int, second: Int = 0) {
    guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
      return nil
    }
    self.date = date
    self.hour = hour
    self.minute = minute
    self.second = second
  }

  public init(_ instant: Date, calendar: Calendar) {
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: instant)
    self.date = CalendarCivilDate(
      year: components.year!, month: components.month!, day: components.day!)!
    self.hour = components.hour!
    self.minute = components.minute!
    self.second = components.second!
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.date, lhs.hour, lhs.minute, lhs.second)
      < (rhs.date, rhs.hour, rhs.minute, rhs.second)
  }

  public func instant(in timeZone: TimeZone) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = DateComponents(
      year: date.year, month: date.month, day: date.day,
      hour: hour, minute: minute, second: second)
    guard let instant = calendar.date(from: components) else { return nil }
    let roundTrip = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: instant)
    guard roundTrip.year == date.year,
      roundTrip.month == date.month,
      roundTrip.day == date.day,
      roundTrip.hour == hour,
      roundTrip.minute == minute,
      roundTrip.second == second
    else { return nil }
    return instant
  }

  var clockDescription: String {
    String(format: "%02d:%02d", hour, minute)
  }

  var stableDescription: String {
    "\(date.stableDescription)T\(String(format: "%02d:%02d:%02d", hour, minute, second))"
  }
}

/// The three distinct temporal concepts EventKit exposes. No case consults the
/// current device zone after construction.
public enum CalendarEventTime: Codable, Equatable, Sendable {
  /// Real instants plus the zone Calendar uses to present their civil time.
  case absolute(start: Date, end: Date, timeZone: TimeZone)
  /// Civil wall-clock values that follow the observer instead of one real instant.
  case floating(start: CalendarCivilDateTime, end: CalendarCivilDateTime)
  /// Civil days; `endExclusive` preserves multi-day all-day events without turning
  /// them into a synthetic 24-hour occupied interval.
  case allDay(start: CalendarCivilDate, endExclusive: CalendarCivilDate)

  public var nativeStartDate: CalendarCivilDate {
    switch self {
    case let .absolute(start, _, timeZone):
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      return CalendarCivilDate(start, calendar: calendar)
    case let .floating(start, _):
      return start.date
    case let .allDay(start, _):
      return start
    }
  }

  public var timeZone: TimeZone? {
    guard case let .absolute(_, _, timeZone) = self else { return nil }
    return timeZone
  }

  /// Project an absolute instant into an explicitly supplied trip/day zone. This
  /// is how a 10:00 Eastern call can constrain the correct civil day in Italy.
  /// Floating and all-day values already carry their civil date.
  public func startDate(in timeZone: TimeZone) -> CalendarCivilDate {
    switch self {
    case let .absolute(start, _, _):
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      return CalendarCivilDate(start, calendar: calendar)
    case let .floating(start, _):
      return start.date
    case let .allDay(start, _):
      return start
    }
  }

  public func resolvedInterval(interpretingFloatingIn timeZone: TimeZone) -> DateInterval? {
    switch self {
    case let .absolute(start, end, _):
      guard end > start else { return nil }
      return DateInterval(start: start, end: end)
    case let .floating(start, end):
      guard let start = start.instant(in: timeZone), let end = end.instant(in: timeZone), end > start else {
        return nil
      }
      return DateInterval(start: start, end: end)
    case .allDay:
      return nil
    }
  }

  var isValid: Bool {
    switch self {
    case let .absolute(start, end, _): end > start
    case let .floating(start, end): end > start
    case let .allDay(start, endExclusive): endExclusive > start
    }
  }

  var stableDescription: String {
    switch self {
    case let .absolute(start, end, timeZone):
      "absolute:\(Self.stable(start)):\(Self.stable(end)):\(timeZone.identifier)"
    case let .floating(start, end):
      "floating:\(start.stableDescription):\(end.stableDescription)"
    case let .allDay(start, endExclusive):
      "allDay:\(start.stableDescription):\(endExclusive.stableDescription)"
    }
  }

  public var identityDescription: String { stableDescription }

  private static func stable(_ value: Date) -> String {
    String(value.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
  }
}

/// A dated trip's inclusive civil days, represented with an exclusive upper bound.
/// The EventKit query may be padded, but this pure scope decides actual inclusion.
public struct CalendarTripScope: Equatable, Sendable {
  public let start: CalendarCivilDate
  public let endExclusive: CalendarCivilDate
  public let dayCount: Int

  public init?(start: CalendarCivilDate, dayCount: Int) {
    guard dayCount > 0, let endExclusive = start.adding(days: dayCount) else { return nil }
    self.start = start
    self.endExclusive = endExclusive
    self.dayCount = dayCount
  }

  public func queryInterval(
    in timeZone: TimeZone,
    paddingDays: Int = 2
  ) -> DateInterval? {
    guard paddingDays >= 0,
      let paddedStart = start.adding(days: -paddingDays)?.date(in: timeZone),
      let paddedEnd = endExclusive.adding(days: paddingDays)?.date(in: timeZone),
      paddedEnd > paddedStart
    else { return nil }
    return DateInterval(start: paddedStart, end: paddedEnd)
  }

  /// Whether a semantic event overlaps these trip days. Absolute instants require
  /// an explicit itinerary/day zone; nil means the caller must retain the event as
  /// unresolved rather than silently using its display zone or the device zone.
  public func overlaps(
    _ temporal: CalendarEventTime,
    absoluteTimeZone: TimeZone?
  ) -> Bool? {
    switch temporal {
    case let .absolute(eventStart, eventEnd, _):
      guard let timeZone = absoluteTimeZone else { return nil }
      guard let start = start.date(in: timeZone),
        let end = endExclusive.date(in: timeZone)
      else { return false }
      return eventStart < end && eventEnd > start
    case let .floating(eventStart, eventEnd):
      guard let start = CalendarCivilDateTime(date: start, hour: 0, minute: 0),
        let end = CalendarCivilDateTime(date: endExclusive, hour: 0, minute: 0)
      else { return false }
      return eventStart < end && eventEnd > start
    case let .allDay(eventStart, eventEnd):
      return eventStart < endExclusive && eventEnd > start
    }
  }
}

/// The result of projecting one Calendar value onto the trip's numbered civil
/// days. An absolute instant is never projected without an explicit itinerary
/// zone; that ambiguity remains visible to reconciliation.
public enum CalendarTripDayProjection: Equatable, Sendable {
  case day(DayNumber, timeZone: TimeZone?)
  case outsideTrip
  case unresolvedTimeZone

  public var dayNumber: DayNumber? {
    guard case let .day(day, _) = self else { return nil }
    return day
  }

  public var timeZone: TimeZone? {
    guard case let .day(_, timeZone) = self else { return nil }
    return timeZone
  }
}

/// The stable inputs needed to project Calendar values onto a dated itinerary.
/// `tripStart` is captured in the same calendar frame that renders the itinerary.
/// It remains one civil-day fact for every event type: absolute events alone use
/// their matched travel zone to determine the event's own civil day.
public struct CalendarTripTemporalContext: Equatable, Sendable {
  public let tripStart: CalendarCivilDate
  public let dayCount: Int

  public init?(tripStart: CalendarCivilDate, dayCount: Int) {
    guard dayCount > 0 else { return nil }
    self.tripStart = tripStart
    self.dayCount = dayCount
  }

  public init(scope: CalendarTripScope) {
    tripStart = scope.start
    dayCount = scope.dayCount
  }

  public func project(
    _ temporal: CalendarEventTime,
    absoluteTimeZone: TimeZone?
  ) -> CalendarTripDayProjection {
    let timeZone: TimeZone
    switch temporal {
    case .absolute:
      guard let absoluteTimeZone else { return .unresolvedTimeZone }
      timeZone = absoluteTimeZone
    case .floating, .allDay:
      timeZone = TimeZone(secondsFromGMT: 0)!
    }

    let eventStart = temporal.startDate(in: timeZone)
    guard let day = eventStart.dayNumber(since: tripStart),
      (1...dayCount).contains(day)
    else { return .outsideTrip }
    return .day(day, timeZone: temporal.timeZone == nil ? nil : timeZone)
  }
}

/// EventKit's scheduling availability, kept separate from the time shape. A free
/// event can still be relevant to reconciliation without occupying itinerary time.
public enum CalendarEventAvailability: String, Codable, Equatable, Sendable {
  case notSupported
  case busy
  case free
  case tentative
  case unavailable
}

/// The plan-repair meaning of an observed event. All-day context and free events
/// never manufacture hard occupied intervals; tentative remains distinguishable.
public enum CalendarEventOccupancy: String, Codable, Equatable, Sendable {
  case dayContext
  case busy
  case free
  case tentative
  case unavailable
  case unknown

  public var isHardOccupied: Bool {
    // Sources that cannot report availability remain unknown instead of being
    // promoted to busy. Plan repair must surface that uncertainty rather than
    // inventing a hard constraint from an unsupported EventKit field.
    self == .busy || self == .unavailable
  }
}

/// The original scheduled occurrence, which remains stable when one recurrence is
/// detached and moved. Combined with the server series identity, it identifies one
/// occurrence without importing or binding the whole recurring series.
public enum CalendarOccurrenceAnchor: Codable, Equatable, Sendable {
  case absolute(Date)
  case floating(CalendarCivilDateTime)
  case allDay(CalendarCivilDate)

  var stableDescription: String {
    switch self {
    case let .absolute(date):
      "absolute:\(String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16))"
    case let .floating(dateTime):
      "floating:\(dateTime.stableDescription)"
    case let .allDay(date):
      "allDay:\(date.stableDescription)"
    }
  }
}

public struct CalendarEventRecurrence: Codable, Equatable, Sendable {
  public let originalOccurrence: CalendarOccurrenceAnchor
  public let isDetached: Bool

  public init(originalOccurrence: CalendarOccurrenceAnchor, isDetached: Bool) {
    self.originalOccurrence = originalOccurrence
    self.isDetached = isDetached
  }
}

/// The Calendar-authored fact retained by bindings, history, and the shared ledger.
/// It is a struct so availability cannot be accidentally dropped from a time value.
public struct CalendarCommitment: Codable, Equatable, Sendable {
  public let temporal: CalendarEventTime
  public let availability: CalendarEventAvailability

  public init?(
    temporal: CalendarEventTime,
    availability: CalendarEventAvailability
  ) {
    guard temporal.isValid else { return nil }
    self.temporal = temporal
    self.availability = availability
  }

  public init?(event: CalendarObservedEvent) {
    self.init(temporal: event.temporal, availability: event.availability)
  }

  public var occupancy: CalendarEventOccupancy {
    if case .allDay = temporal { return .dayContext }
    return switch availability {
    case .busy: .busy
    case .free: .free
    case .tentative: .tentative
    case .unavailable: .unavailable
    case .notSupported: .unknown
    }
  }

  public var pinnedDate: Date? {
    guard case let .absolute(start, _, _) = temporal else { return nil }
    return start
  }

  public func schedule(on day: DayNumber) -> Schedule {
    switch temporal {
    case .allDay:
      return .day(day)
    case let .absolute(start, end, timeZone):
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      return .timed(
        day,
        start: Self.clockTime(start, calendar: calendar),
        end: Self.clockTime(end, calendar: calendar))
    case let .floating(start, end):
      return .timed(day, start: start.clockDescription, end: end.clockDescription)
    }
  }

  public func hardOccupiedInterval(
    interpretingFloatingIn timeZone: TimeZone
  ) -> DateInterval? {
    guard occupancy.isHardOccupied else { return nil }
    return temporal.resolvedInterval(interpretingFloatingIn: timeZone)
  }

  /// Compatibility factories for call sites and stored Slice 2 fixtures. New
  /// EventKit ingestion constructs the explicit temporal cases instead.
  public static func timed(
    start: Date,
    end: Date,
    timeZone: TimeZone = .current,
    availability: CalendarEventAvailability = .notSupported
  ) -> Self {
    Self(temporal: .absolute(start: start, end: end, timeZone: timeZone), availability: availability)!
  }

  public static func allDay(
    date: Date,
    calendar: Calendar = .current,
    availability: CalendarEventAvailability = .notSupported
  ) -> Self {
    let start = CalendarCivilDate(date, calendar: calendar)
    let utc = TimeZone(secondsFromGMT: 0)!
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = utc
    let startDate = start.date(in: utc)!
    let nextDate = gregorian.date(byAdding: .day, value: 1, to: startDate)!
    let end = CalendarCivilDate(nextDate, calendar: gregorian)
    return Self(temporal: .allDay(start: start, endExclusive: end), availability: availability)!
  }

  private static func clockTime(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
  }

  private enum Legacy: Codable {
    case allDay(date: Date)
    case timed(start: Date, end: Date)
  }

  private enum CodingKeys: String, CodingKey {
    case temporal
    case availability
  }

  public init(from decoder: Decoder) throws {
    if let container = try? decoder.container(keyedBy: CodingKeys.self),
      let temporal = try? container.decode(CalendarEventTime.self, forKey: .temporal)
    {
      let availability = try container.decode(
        CalendarEventAvailability.self, forKey: .availability)
      guard let value = Self(temporal: temporal, availability: availability) else {
        throw DecodingError.dataCorruptedError(
          forKey: .temporal,
          in: container,
          debugDescription: "Calendar commitment has an invalid temporal range.")
      }
      self = value
      return
    }

    switch try Legacy(from: decoder) {
    case let .allDay(date):
      self = .allDay(date: date)
    case let .timed(start, end):
      self = .timed(start: start, end: end)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(temporal, forKey: .temporal)
    try container.encode(availability, forKey: .availability)
  }
}
