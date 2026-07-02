import Foundation

/// A day of the week, Monday-first (the itinerary's natural order), stored by a
/// stable `Int` raw value. Distinct from `Foundation`'s Sunday-first
/// `Calendar` weekday numbering — `init(calendarWeekday:)` / `from(_ date:)`
/// bridge across. Raw values are persisted inside the encoded `WeeklyHours`
/// column; never renumber.
public enum Weekday: Int, CaseIterable, Codable, Sendable {
  case monday = 0
  case tuesday = 1
  case wednesday = 2
  case thursday = 3
  case friday = 4
  case saturday = 5
  case sunday = 6

  /// From Foundation's 1=Sunday…7=Saturday `Calendar` weekday component.
  public init?(calendarWeekday: Int) {
    switch calendarWeekday {
    case 1: self = .sunday
    case 2: self = .monday
    case 3: self = .tuesday
    case 4: self = .wednesday
    case 5: self = .thursday
    case 6: self = .friday
    case 7: self = .saturday
    default: return nil
    }
  }

  /// The weekday a calendar `date` falls on (Gregorian, current calendar).
  public static func from(_ date: Date, calendar: Calendar = .current) -> Weekday? {
    Weekday(calendarWeekday: calendar.component(.weekday, from: date))
  }

  /// The weekday `offset` days after this one, wrapping the week — the engine of
  /// the start-day solver (day 1 = start weekday, day N = start + N-1).
  public func adding(days offset: Int) -> Weekday {
    let wrapped = ((rawValue + offset) % 7 + 7) % 7
    return Weekday(rawValue: wrapped) ?? self
  }

  public var label: String {
    switch self {
    case .monday: "Monday"
    case .tuesday: "Tuesday"
    case .wednesday: "Wednesday"
    case .thursday: "Thursday"
    case .friday: "Friday"
    case .saturday: "Saturday"
    case .sunday: "Sunday"
    }
  }

  public var shortLabel: String { String(label.prefix(3)) }
}

/// A meal service — the planning-relevant unit of a restaurant's day. A restaurant
/// running split lunch/dinner service is "open" all afternoon on paper yet closed
/// for the meal you want; treating meal service as first-class (ADR-0029 §1) makes
/// "open *for dinner*" a direct question. `String` raw values are stable; extensible
/// (v1's solver drives on `.lunch` / `.dinner`).
public enum Meal: String, CaseIterable, Codable, Sendable {
  case breakfast
  case lunch
  case dinner
  case lateNight

  public var label: String {
    switch self {
    case .breakfast: "Breakfast"
    case .lunch: "Lunch"
    case .dinner: "Dinner"
    case .lateNight: "Late Night"
    }
  }

  /// The fixed clock window (minutes from midnight) a bare clock interval must
  /// overlap to count as serving this meal, when the source gave no meal label
  /// (ADR-0029 §1 — "v1 fixed, later locale-aware"). Deliberately generous so a
  /// long service reads as covering the meal it straddles. `lateNight` runs past
  /// midnight (its close exceeds 1440).
  public var window: OpenInterval {
    switch self {
    case .breakfast: OpenInterval(open: 6 * 60, close: 10 * 60 + 30)
    case .lunch: OpenInterval(open: 11 * 60, close: 15 * 60)
    case .dinner: OpenInterval(open: 17 * 60, close: 22 * 60)
    case .lateNight: OpenInterval(open: 22 * 60, close: 26 * 60)
    }
  }

  /// The meal a clock `minute`-of-day implies when a food stop is scheduled at a
  /// time but its hours carry no meal label — the bridge the solver uses to turn an
  /// evening booking into a "serves dinner?" question (ADR-0029 §4). Coarse buckets,
  /// not window membership, so a 16:30 stop still maps somewhere.
  public static func forClock(minute: Int) -> Meal {
    switch minute {
    case ..<(11 * 60): .breakfast
    case ..<(17 * 60): .lunch
    case ..<(22 * 60): .dinner
    default: .lateNight
    }
  }
}

/// A clock interval within a single day, as minutes from midnight. `close` may
/// exceed 1440 for service that runs past midnight (a 22:00–02:00 late-night
/// sitting is `open: 1320, close: 1560`). Pure value; the optional bonus atop the
/// weekday-level open/closed the solver actually needs (ADR-0029 §1).
public struct OpenInterval: Equatable, Codable, Sendable {
  public var open: Int
  public var close: Int

  public init(open: Int, close: Int) {
    self.open = open
    self.close = close
  }

  /// Do these two intervals share any minute? Used to test a bare interval against
  /// a `Meal.window`.
  public func overlaps(_ other: OpenInterval) -> Bool {
    open < other.close && other.open < close
  }

  /// `"HH:mm"` for a minute-of-day, wrapping a past-midnight close back into 24h.
  static func clock(_ minute: Int) -> String {
    let m = ((minute % (24 * 60)) + 24 * 60) % (24 * 60)
    return String(format: "%02d:%02d", m / 60, m % 60)
  }

  /// `"HH:mm–HH:mm"` for display.
  public var display: String { "\(Self.clock(open))–\(Self.clock(close))" }
}

/// One service period ("sitting") on a day: a meal label, a clock interval, or
/// both. At least one is present (an empty period carries no information); a
/// source stating *"dinner only"* arrives `meal: .dinner, interval: nil` (no
/// fabricated clock), a schema.org interval arrives `meal: nil` (the meal derives
/// on read), a source stating both fills both. See ADR-0029 §1.
public struct ServicePeriod: Equatable, Codable, Sendable {
  public var meal: Meal?
  public var interval: OpenInterval?

  public init(meal: Meal? = nil, interval: OpenInterval? = nil) {
    self.meal = meal
    self.interval = interval
  }

  /// Does this sitting serve `meal`? The label if present, else the interval
  /// overlapped against the meal's window. A period with neither (shouldn't occur
  /// — the invariant guards it) asserts nothing.
  public func serves(_ meal: Meal) -> Bool? {
    if let label = self.meal { return label == meal }
    if let interval { return interval.overlaps(meal.window) }
    return nil
  }

  /// A compact label for display: "Dinner 18:00–22:00", "Dinner", or "12:00–14:00".
  public var display: String {
    switch (meal, interval) {
    case let (meal?, interval?): "\(meal.label) \(interval.display)"
    case let (meal?, nil): meal.label
    case let (nil, interval?): interval.display
    case (nil, nil): "Open"
    }
  }
}

/// A single day's openness. `.unknown` is deliberately distinct from `.closed`: a
/// page silent on Tuesday is not *asserting* closed, so the solver must never raise
/// a false "closed" alarm from missing data (ADR-0029 §1). `.open([])` is "open,
/// no service detail" — open for the plain check, silent on any meal.
public enum DayHours: Equatable, Codable, Sendable {
  case closed
  case unknown
  case open([ServicePeriod])

  public var isClosed: Bool {
    if case .closed = self { return true }
    return false
  }

  /// A compact one-line label for display: "Closed", "—" (unknown), "Open", or the
  /// day's sittings ("Lunch 12:00–14:00, Dinner 19:00–22:00").
  public var display: String {
    switch self {
    case .closed: "Closed"
    case .unknown: "—"
    case let .open(periods):
      periods.isEmpty ? "Open" : periods.map(\.display).joined(separator: ", ")
    }
  }

  /// Does this day serve `meal`? `nil` = no assertion (`.unknown`, or `.open` with
  /// no service detail); `false` = open but not for this meal (the "does lunch, we
  /// wanted dinner" conflict); `true` = a sitting covers it. `.closed → false`.
  public func serves(_ meal: Meal) -> Bool? {
    switch self {
    case .unknown:
      return nil
    case .closed:
      return false
    case let .open(periods):
      guard !periods.isEmpty else { return nil }
      let results = periods.compactMap { $0.serves(meal) }
      guard !results.isEmpty else { return nil }
      return results.contains(true)
    }
  }
}

/// Structured weekday opening hours — seven `DayHours`, one per `Weekday`
/// (Mon…Sun) — the representation the start-day solver reads (ADR-0029 §1). Pure,
/// `Codable`, no I/O: a functional-core value type stored as one encoded string
/// column behind this facade, never queried in SQL. The free-form
/// `Idea.openingHours` string stays the faithful captured source of truth; this is
/// the derived, hand-editable structure.
public struct WeeklyHours: Equatable, Codable, Sendable {
  /// Exactly seven entries, indexed by `Weekday.rawValue`. `init` pads/truncates to
  /// seven with `.unknown` so the invariant always holds, even after a lossy decode.
  public private(set) var days: [DayHours]

  public init(days: [DayHours]) {
    var normalized = Array(days.prefix(7))
    while normalized.count < 7 { normalized.append(.unknown) }
    self.days = normalized
  }

  /// All-unknown — the "we have no structured hours" value the parser/editor start
  /// from, and what an absent column decodes to.
  public static var unknown: WeeklyHours { WeeklyHours(days: Array(repeating: .unknown, count: 7)) }

  public subscript(_ weekday: Weekday) -> DayHours {
    get { days[weekday.rawValue] }
    set { days[weekday.rawValue] = newValue }
  }

  /// True once any day carries an assertion — the panel/editor use it to tell
  /// "structured" apart from "all unknown."
  public var hasAnyAssertion: Bool { days.contains { $0 != .unknown } }

  public func serves(_ meal: Meal, on weekday: Weekday) -> Bool? {
    self[weekday].serves(meal)
  }

  public func isClosed(on weekday: Weekday) -> Bool { self[weekday].isClosed }

  // MARK: Column encoding

  /// The value stored in `Idea.structuredHours` (a CloudKit-legal string), or `nil`
  /// when nothing is asserted (store no column rather than an all-unknown blob).
  public func encoded() -> String? {
    guard hasAnyAssertion, let data = try? JSONEncoder().encode(self) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// Decode a stored column value; `nil` on absent or malformed JSON (degrades to
  /// "no structured hours," never a crash).
  public static func decode(_ json: String?) -> WeeklyHours? {
    guard let data = json?.data(using: .utf8),
      let value = try? JSONDecoder().decode(WeeklyHours.self, from: data)
    else { return nil }
    return value
  }
}
