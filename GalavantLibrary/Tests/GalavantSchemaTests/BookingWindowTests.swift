import Foundation
import Testing
@testable import GalavantSchema

@Suite struct BookingWindowTests {
  @Test func daysAheadUsesRestaurantCivilTimeAcrossSweetBasilBoundary() throws {
    let zone = try #require(TimeZone(identifier: "America/Denver"))
    let rule = BookingWindowRule.daysAhead(30, releaseTime: LocalTime(hour: 9, minute: 0))
    let result = try #require(rule.opening(
      forMealOn: LocalDate(year: 2027, month: 2, day: 9), mealTime: nil, in: zone, now: .now))
    let components = Calendar.current.dateComponents(in: zone, from: result)
    #expect(components.year == 2027)
    #expect(components.month == 1)
    #expect(components.day == 10)
    #expect(components.hour == 9)
    #expect(components.minute == 0)
  }

  @Test func monthlyInvalidDayReturnsNilAndYearBoundaryIsHandled() throws {
    let zone = try #require(TimeZone(identifier: "UTC"))
    let rule = BookingWindowRule.monthly(dayOfMonth: 1, monthsAhead: 1, releaseTime: nil)
    let result = try #require(rule.opening(
      forMealOn: LocalDate(year: 2027, month: 1, day: 15), mealTime: nil, in: zone, now: .now))
    let components = Calendar(identifier: .gregorian).dateComponents(in: zone, from: result)
    #expect(components.year == 2026)
    #expect(components.month == 12)
    #expect(BookingWindowRule.monthly(dayOfMonth: 31, monthsAhead: 1, releaseTime: nil)
      .opening(forMealOn: LocalDate(year: 2027, month: 3, day: 31), mealTime: nil, in: zone, now: .now) == nil)
  }

  @Test func daysAheadKeepsCivilTimeAcrossDSTAndMonthEnd() throws {
    let zone = try #require(TimeZone(identifier: "America/Denver"))
    let nineAM = LocalTime(hour: 9, minute: 0)
    let dstOpening = try #require(BookingWindowRule.daysAhead(1, releaseTime: nineAM).opening(
      forMealOn: LocalDate(year: 2027, month: 3, day: 14), mealTime: nil, in: zone, now: .now))
    let dstParts = Calendar(identifier: .gregorian).dateComponents(in: zone, from: dstOpening)
    #expect(dstParts.month == 3)
    #expect(dstParts.day == 13)
    #expect(dstParts.hour == 9)
    let monthEnd = try #require(BookingWindowRule.daysAhead(30, releaseTime: nineAM).opening(
      forMealOn: LocalDate(year: 2027, month: 3, day: 31), mealTime: nil, in: zone, now: .now))
    let monthParts = Calendar(identifier: .gregorian).dateComponents(in: zone, from: monthEnd)
    #expect(monthParts.month == 3)
    #expect(monthParts.day == 1)
    #expect(monthParts.hour == 9)
  }

  @Test func windowRoundTripsAndMalformedHandoffIsDropped() throws {
    let window = BookingWindow(
      rule: .daysAhead(30, releaseTime: LocalTime(hour: 9, minute: 0)), timeZoneID: "America/Denver",
      sourceURL: "https://example.com/reservations", quote: "Reservations open 30 days ahead.", foundAt: Date(timeIntervalSince1970: 10))
    #expect(BookingWindow.decode(window.encoded()) == window)
    #expect(BookingWindow.fromHandoff(["kind": "unknown"], now: .now) == nil)
    #expect(BookingWindow.fromHandoff(["kind": "days_ahead", "source_url": "https://x.test", "quote": "x"], now: .now) == nil)
    #expect(BookingWindow.fromHandoff(["kind": "days_ahead", "days": 30, "release_time": "bad", "source_url": "https://x.test", "quote": "x"], now: .now) == nil)
  }
}
