import CustomDump
import Foundation
import GalavantSchema
import Testing

@Suite struct WeatherRequestPolicyTests {
  private let coordinate = WeatherAnchor.Coordinate(latitude: 40.71281, longitude: -74.00601)

  @Test func granularityFollowsTheAnchorScheduleAndSensitivity() {
    expectNoDifference(
      anchor(window: .interval(DateInterval(start: date(15), duration: 90 * 60))).weatherGranularity,
      .hourlyInterval)
    expectNoDifference(anchor(window: .hour(date(15))).weatherGranularity, .hourlyInterval)
    expectNoDifference(anchor(window: .daypart(dayStart: date(15), .afternoon)).weatherGranularity, .daily)
    expectNoDifference(
      anchor(window: .daypart(dayStart: date(15), .afternoon), isWeatherSensitive: true).weatherGranularity,
      .hourlyInterval)
    expectNoDifference(anchor(window: .daily(date(15))).weatherGranularity, .daily)
  }

  @Test func overnightUsesTheNextCivilMorningAcrossSpringForward() {
    let interval = WeatherAnchor.TimeWindow
      .daypart(dayStart: date(8, month: 3), .overNight)
      .hourlyInterval(in: newYorkCalendar)

    expectNoDifference(components(of: interval.start), DateComponents(year: 2026, month: 3, day: 9, hour: 0))
    expectNoDifference(components(of: interval.end), DateComponents(year: 2026, month: 3, day: 9, hour: 6))
    #expect(interval.end > interval.start)
  }

  @Test func cacheKeyRoundsCoordinatesAndUsesTheQueryScope() {
    let daily = WeatherAnchor.TimeWindow.daily(date(15))
    let daypart = WeatherAnchor.TimeWindow.daypart(dayStart: date(15), .afternoon)
    let nearby = WeatherAnchor.Coordinate(latitude: 40.71284, longitude: -74.00604)
    let distinct = WeatherAnchor.Coordinate(latitude: 40.7131, longitude: -74.0063)

    let key = WeatherAnchor.CacheKey(
      coordinate: coordinate, window: daily, granularity: .daily, calendar: newYorkCalendar)
    let nearbyKey = WeatherAnchor.CacheKey(
      coordinate: nearby, window: daypart, granularity: .daily, calendar: newYorkCalendar)
    let distinctKey = WeatherAnchor.CacheKey(
      coordinate: distinct, window: daily, granularity: .daily, calendar: newYorkCalendar)
    let currentKey = WeatherAnchor.CacheKey(
      coordinate: coordinate, window: daily, granularity: .current, calendar: newYorkCalendar)

    #expect(key == nearbyKey)
    #expect(key != distinctKey)
    #expect(key != currentKey)
  }

  @Test func dailySelectionAndExpirationUseTheEarliestRelevantDate() {
    let dates = [date(14), date(15), date(16)]
    let index = WeatherAnchor.TimeWindow.daily(date(15)).nearestDailyForecastIndex(in: dates)

    expectNoDifference(index, 1)
    expectNoDifference(WeatherExpiration.earliest(in: dates), date(14))
  }

  private func anchor(
    window: WeatherAnchor.TimeWindow,
    isWeatherSensitive: Bool = false
  ) -> WeatherAnchor {
    WeatherAnchor(coordinate: coordinate, timeWindow: window, isWeatherSensitive: isWeatherSensitive)
  }

  private var newYorkCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
  }

  private func date(_ day: Int, month: Int = 8, hour: Int = 12) -> Date {
    newYorkCalendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  private func components(of date: Date) -> DateComponents {
    let components = newYorkCalendar.dateComponents([.year, .month, .day, .hour], from: date)
    return DateComponents(
      year: components.year,
      month: components.month,
      day: components.day,
      hour: components.hour)
  }
}
