import CustomDump
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

  @Test func suggestionUsesWindowTimeZoneAndAllowsRuleOnlyWithoutMealDate() throws {
    let bookingZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
    let dayZone = try #require(TimeZone(identifier: "UTC"))
    let window = BookingWindow(
      rule: .daysAhead(30, releaseTime: LocalTime(hour: 9, minute: 0)), timeZoneID: bookingZone.identifier,
      sourceURL: "https://example.com", quote: "Thirty days", foundAt: Date(timeIntervalSince1970: 1))
    let mealDate = LocalDate(year: 2027, month: 6, day: 30)
    let suggestion = try #require(BookingSuggestion.make(
      status: .toBook, kind: .food, hasOpeningDate: false, mealDate: mealDate,
      mealTime: nil, dayTimeZone: dayZone, window: window, now: Date(timeIntervalSince1970: 0)))
    let opening = try #require(suggestion.opensAt)
    let parts = Calendar(identifier: .gregorian).dateComponents(in: bookingZone, from: opening)
    #expect(parts.hour == 9)
    #expect(parts.minute == 0)

    let dayZoneWindow = BookingWindow(
      rule: .daysAhead(30, releaseTime: LocalTime(hour: 9, minute: 0)), timeZoneID: nil,
      sourceURL: "https://example.com", quote: "Thirty days", foundAt: Date(timeIntervalSince1970: 1))
    let dayZoneSuggestion = try #require(BookingSuggestion.make(
      status: .toBook, kind: .food, hasOpeningDate: false, mealDate: mealDate,
      mealTime: nil, dayTimeZone: dayZone, window: dayZoneWindow, now: Date(timeIntervalSince1970: 0)))
    let dayZoneOpening = try #require(dayZoneSuggestion.opensAt)
    let dayZoneParts = Calendar(identifier: .gregorian).dateComponents(in: dayZone, from: dayZoneOpening)
    #expect(dayZoneParts.hour == 9)
    #expect(dayZoneParts.minute == 0)

    let ruleOnly = try #require(BookingSuggestion.make(
      status: .toBook, kind: .food, hasOpeningDate: false, mealDate: nil,
      mealTime: nil, dayTimeZone: dayZone, window: window, now: Date(timeIntervalSince1970: 0)))
    #expect(ruleOnly.opensAt == nil)
    #expect(ruleOnly.rule == window.rule)
  }

  @Test func suggestionRequiresAnUnscheduledFoodIdeaMarkedToBook() throws {
    let zone = try #require(TimeZone(identifier: "UTC"))
    let window = BookingWindow(
      rule: .anyTime, timeZoneID: nil, sourceURL: "https://example.com", quote: "Any time",
      foundAt: Date(timeIntervalSince1970: 1))
    let args: [(BookingStatus?, IdeaKind?, Bool)] = [
      (.booked, .food, false), (.notNeeded, .food, false), (nil, .food, false),
      (.toBook, .activity, false), (.toBook, .stay, false), (.toBook, .food, true),
    ]
    for (status, kind, hasOpeningDate) in args {
      #expect(BookingSuggestion.make(
        status: status, kind: kind, hasOpeningDate: hasOpeningDate, mealDate: nil,
        mealTime: nil, dayTimeZone: zone, window: window, now: Date(timeIntervalSince1970: 0)) == nil)
    }
    #expect(BookingSuggestion.make(
      status: .toBook, kind: .food, hasOpeningDate: false, mealDate: nil,
      mealTime: nil, dayTimeZone: zone, window: nil, now: Date(timeIntervalSince1970: 0)) == nil)
  }

  @Test func ruleFormattingUsesSuppliedTimeZoneAndHumanizesDateAndCounts() throws {
    let kiritimati = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
    let formatted = BookingOpeningFormat.ruleString(
      .daysAhead(1, releaseTime: LocalTime(hour: 9, minute: 0)), timeZone: kiritimati,
      locale: Locale(identifier: "en_US"))
    #expect(formatted.contains("1 day ahead"))
    #expect(formatted.contains("9:00"))
    #expect(formatted.contains("AM"))
    #expect(BookingOpeningFormat.ruleString(
      .monthly(dayOfMonth: 1, monthsAhead: 1, releaseTime: nil), timeZone: kiritimati
    ).contains("1 month ahead"))
    let fixed = BookingOpeningFormat.ruleString(
      .fixedDate(LocalDateTime(date: LocalDate(year: 2027, month: 2, day: 1), time: LocalTime(hour: 10, minute: 0)!)),
      timeZone: kiritimati, locale: Locale(identifier: "en_US"))
    #expect(!fixed.contains("2027-02-01"))
  }
}
