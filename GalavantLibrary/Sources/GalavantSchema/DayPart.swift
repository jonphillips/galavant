import SQLiteData

/// A coarse time-of-day bucket for an itinerary stop, between "no time at all"
/// and an exact clock time (the `Schedule` middle ground). Ported from V2's
/// `DayPart`; `Int` raw values (V2 used strings) keep storage compact and let
/// `sortHour` order a day's stops. Raw values order the day — never renumber.
public enum DayPart: Int, QueryBindable, CaseIterable, Sendable, Identifiable {
  case earlyMorning = 0
  case breakfast = 1
  case morning = 2
  case lunch = 3
  case afternoon = 4
  case dinner = 5
  case evening = 6
  case lateNight = 7
  case overNight = 8

  public var id: Int { rawValue }

  public var label: String {
    switch self {
    case .earlyMorning: "Early Morning"
    case .breakfast: "Breakfast"
    case .morning: "Morning"
    case .lunch: "Lunch"
    case .afternoon: "Afternoon"
    case .dinner: "Dinner"
    case .evening: "Evening"
    case .lateNight: "Late Night"
    case .overNight: "Overnight"
    }
  }

  public var systemImage: String {
    switch self {
    case .earlyMorning: "sunrise"
    case .breakfast: "cup.and.saucer"
    case .morning: "sun.haze"
    case .lunch: "takeoutbag.and.cup.and.straw"
    case .afternoon: "sun.max"
    case .dinner: "fork.knife"
    case .evening: "sun.horizon"
    case .lateNight: "moon"
    case .overNight: "moon.zzz"
    }
  }

  /// Representative hour of the day (0–24) for intra-day sorting against clock
  /// times — a daypart sorts as if it started at this hour.
  public var sortHour: Int {
    switch self {
    case .earlyMorning: 6
    case .breakfast: 8
    case .morning: 10
    case .lunch: 12
    case .afternoon: 14
    case .dinner: 18
    case .evening: 20
    case .lateNight: 22
    case .overNight: 24
    }
  }
}
