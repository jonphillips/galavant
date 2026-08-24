import Foundation

/// The forecast shape an anchor needs. The app's WeatherKit adapter translates
/// this pure request policy into the framework-specific query.
public extension WeatherAnchor {
  enum Granularity: Hashable, Sendable {
    case current
    case daily
    case hourlyInterval
  }

  var weatherGranularity: Granularity {
    switch timeWindow {
    case .interval, .hour:
      .hourlyInterval
    case .daypart:
      isWeatherSensitive ? .hourlyInterval : .daily
    case .daily:
      .daily
    }
  }

  /// An in-memory WeatherKit response key. Coordinates use a four-decimal grid
  /// (roughly 11 m at the equator) so repeated resolutions for one planned stop
  /// share a response without merging distinct places.
  struct CacheKey: Hashable, Sendable {
    private static let coordinateScale = 10_000.0

    private var latitude: Int
    private var longitude: Int
    private var window: Window
    private var granularity: Granularity

    public init(
      coordinate: Coordinate,
      window: TimeWindow,
      granularity: Granularity,
      calendar: Calendar = .current
    ) {
      latitude = Int((coordinate.latitude * Self.coordinateScale).rounded())
      longitude = Int((coordinate.longitude * Self.coordinateScale).rounded())
      self.window = Window(window: window, granularity: granularity, calendar: calendar)
      self.granularity = granularity
    }

    private enum Window: Hashable, Sendable {
      case current
      case daily(Date)
      case interval(Date, Date)

      init(window: TimeWindow, granularity: Granularity, calendar: Calendar) {
        switch granularity {
        case .current:
          self = .current
        case .daily:
          self = .daily(calendar.startOfDay(for: window.forecastReferenceDate))
        case .hourlyInterval:
          let interval = window.hourlyInterval(in: calendar)
          self = .interval(interval.start, interval.end)
        }
      }
    }
  }
}

public extension WeatherAnchor.TimeWindow {
  var forecastReferenceDate: Date {
    switch self {
    case let .interval(interval): interval.start
    case let .hour(date), let .daily(date): date
    case let .daypart(dayStart, _): dayStart
    }
  }

  func hourlyInterval(in calendar: Calendar = .current) -> DateInterval {
    switch self {
    case let .interval(interval):
      return interval
    case let .hour(date):
      return DateInterval(start: date, duration: 60 * 60)
    case let .daypart(dayStart, part):
      return DateInterval(
        start: daypartStart(part, on: dayStart, calendar: calendar),
        end: daypartEnd(after: part, on: dayStart, calendar: calendar))
    case let .daily(date):
      let start = calendar.startOfDay(for: date)
      let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
      return DateInterval(start: start, end: end)
    }
  }

  /// The index of the daily forecast covering `forecastReferenceDate`, or `nil` when
  /// the date lies outside the forecast's horizon.
  ///
  /// WeatherKit returns only a bounded window of daily forecasts (~10 days out).
  /// Without the horizon guard, a planned day past that window has no forecast of its
  /// own, so the nearest-by-distance pick collapses onto the *last* available day and
  /// repeats it across every too-far-out day. Returning `nil` there is correct: no
  /// forecast is the primary, expected state for days beyond the horizon (ADR-0038).
  func nearestDailyForecastIndex(in dates: [Date], calendar: Calendar = .current) -> Int? {
    guard let earliest = dates.min(), let latest = dates.max() else { return nil }
    let reference = forecastReferenceDate
    let horizonEnd = calendar.date(byAdding: .day, value: 1, to: latest) ?? latest
    guard reference >= calendar.startOfDay(for: earliest), reference < horizonEnd else {
      return nil
    }
    return dates.indices.min {
      abs(dates[$0].timeIntervalSince(reference)) < abs(dates[$1].timeIntervalSince(reference))
    }
  }
}

public enum WeatherExpiration {
  public static func earliest(in dates: [Date]) -> Date? {
    dates.min()
  }
}

private func daypartStart(_ part: DayPart, on dayStart: Date, calendar: Calendar) -> Date {
  civilDate(hour: part.sortHour, on: dayStart, calendar: calendar)
}

private func daypartEnd(after part: DayPart, on dayStart: Date, calendar: Calendar) -> Date {
  if let nextPart = DayPart.allCases
    .filter({ $0.sortHour > part.sortHour })
    .min(by: { $0.sortHour < $1.sortHour })
  {
    return daypartStart(nextPart, on: dayStart, calendar: calendar)
  }

  let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
  return daypartStart(.earlyMorning, on: nextDay, calendar: calendar)
}

private func civilDate(hour: Int, on dayStart: Date, calendar: Calendar) -> Date {
  let day = calendar.date(byAdding: .day, value: hour / 24, to: dayStart) ?? dayStart
  return calendar.date(bySettingHour: hour % 24, minute: 0, second: 0, of: day) ?? day
}
