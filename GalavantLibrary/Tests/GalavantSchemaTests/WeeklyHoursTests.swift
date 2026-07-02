import Foundation
import GalavantSchema
import Testing

@Suite struct WeeklyHoursTests {
  // MARK: Weekday

  @Test("Weekday bridges Foundation's Sunday-first calendar numbering")
  func calendarBridge() {
    #expect(Weekday(calendarWeekday: 1) == .sunday)
    #expect(Weekday(calendarWeekday: 2) == .monday)
    #expect(Weekday(calendarWeekday: 7) == .saturday)
    #expect(Weekday(calendarWeekday: 0) == nil)
    #expect(Weekday(calendarWeekday: 8) == nil)
  }

  @Test("adding(days:) wraps the week in both directions")
  func weekdayAdding() {
    #expect(Weekday.monday.adding(days: 0) == .monday)
    #expect(Weekday.monday.adding(days: 5) == .saturday)
    #expect(Weekday.saturday.adding(days: 2) == .monday)
    #expect(Weekday.monday.adding(days: 7) == .monday)
    #expect(Weekday.monday.adding(days: -1) == .sunday)
    #expect(Weekday.monday.adding(days: 8) == .tuesday)
  }

  // MARK: serves(_:) derivation

  @Test("A labeled dinner-only period serves dinner but not lunch")
  func labeledMeal() {
    let day = DayHours.open([ServicePeriod(meal: .dinner)])
    #expect(day.serves(.dinner) == true)
    #expect(day.serves(.lunch) == false)
    #expect(day.serves(.breakfast) == false)
  }

  @Test("A bare clock interval derives the meal from its window")
  func intervalDerivesMeal() {
    let lunch = DayHours.open([ServicePeriod(interval: OpenInterval(open: 12 * 60, close: 14 * 60))])
    #expect(lunch.serves(.lunch) == true)
    #expect(lunch.serves(.dinner) == false)

    let dinner = DayHours.open([ServicePeriod(interval: OpenInterval(open: 19 * 60, close: 22 * 60))])
    #expect(dinner.serves(.dinner) == true)
    #expect(dinner.serves(.lunch) == false)
  }

  @Test("Split lunch/dinner service serves both meals")
  func splitService() {
    let day = DayHours.open([
      ServicePeriod(interval: OpenInterval(open: 12 * 60, close: 14 * 60)),
      ServicePeriod(interval: OpenInterval(open: 19 * 60, close: 22 * 60)),
    ])
    #expect(day.serves(.lunch) == true)
    #expect(day.serves(.dinner) == true)
    #expect(day.serves(.breakfast) == false)
  }

  @Test("Closed asserts false; unknown and detail-less open assert nothing")
  func closedVsUnknown() {
    #expect(DayHours.closed.serves(.dinner) == false)
    #expect(DayHours.closed.isClosed)
    #expect(DayHours.unknown.serves(.dinner) == nil)
    #expect(DayHours.open([]).serves(.dinner) == nil)  // open, no service detail
    #expect(!DayHours.unknown.isClosed)
    #expect(!DayHours.open([]).isClosed)
  }

  // MARK: WeeklyHours facade

  @Test("WeeklyHours pads to seven days and starts all-unknown")
  func padding() {
    #expect(WeeklyHours.unknown.days.count == 7)
    #expect(!WeeklyHours.unknown.hasAnyAssertion)
    let short = WeeklyHours(days: [.closed])
    #expect(short.days.count == 7)
    #expect(short[.monday] == .closed)
    #expect(short[.sunday] == .unknown)
    #expect(short.hasAnyAssertion)
  }

  @Test("Subscript reads and writes by weekday")
  func subscriptAccess() {
    var hours = WeeklyHours.unknown
    hours[.wednesday] = .open([ServicePeriod(meal: .dinner)])
    #expect(hours.serves(.dinner, on: .wednesday) == true)
    #expect(hours.serves(.dinner, on: .thursday) == nil)
    #expect(hours.isClosed(on: .wednesday) == false)
  }

  @Test("Encode round-trips through the column string; all-unknown encodes to nil")
  func encodeRoundTrip() {
    var hours = WeeklyHours.unknown
    hours[.monday] = .closed
    hours[.tuesday] = .open([ServicePeriod(meal: .lunch, interval: OpenInterval(open: 720, close: 840))])
    let encoded = hours.encoded()
    #expect(encoded != nil)
    #expect(WeeklyHours.decode(encoded) == hours)

    #expect(WeeklyHours.unknown.encoded() == nil)
    #expect(WeeklyHours.decode(nil) == nil)
    #expect(WeeklyHours.decode("not json") == nil)
  }

  // MARK: Meal windows / clock mapping

  @Test("Meal.forClock buckets a clock time to a meal")
  func clockToMeal() {
    #expect(Meal.forClock(minute: 8 * 60) == .breakfast)
    #expect(Meal.forClock(minute: 12 * 60) == .lunch)
    #expect(Meal.forClock(minute: 15 * 60) == .lunch)
    #expect(Meal.forClock(minute: 19 * 60 + 30) == .dinner)
    #expect(Meal.forClock(minute: 23 * 60) == .lateNight)
  }
}
