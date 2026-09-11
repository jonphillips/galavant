import Foundation
import GalavantSchema
import Testing

/// The planning surface's sense of *now*: live-day derivation and the one-shot
/// rule that opens an underway trip on its live day.
@Suite struct PlanningDayLensTests {
  private let length = 5

  private var startDate: Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 15))!
  }

  /// Noon on a 1-based trip day (may run past the trip's last day, deliberately).
  private func noon(onDay day: Int) -> Date {
    let dayDate = Calendar.current.date(byAdding: .day, value: day - 1, to: startDate)!
    return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dayDate)!
  }

  private func liveDay(at now: Date, tripStartDate: Date? = nil) -> Int? {
    TodayProjection.tripDay(
      containing: now, tripStartDate: tripStartDate ?? startDate, lengthInDays: length)
  }

  // MARK: - Live-day derivation

  @Test func liveDayCoversTheWholeTripSpanInclusive() {
    #expect(liveDay(at: noon(onDay: 1)) == 1)
    #expect(liveDay(at: noon(onDay: 3)) == 3)
    #expect(liveDay(at: noon(onDay: length)) == length)
  }

  @Test func liveDayIsNilBeforeTheTripStarts() {
    let theNightBefore = Calendar.current.startOfDay(for: startDate).addingTimeInterval(-1)
    #expect(liveDay(at: theNightBefore) == nil)
    #expect(liveDay(at: noon(onDay: -3)) == nil)
  }

  @Test func liveDayIsNilAfterTheTripEnds() {
    #expect(liveDay(at: noon(onDay: length + 1)) == nil)
    #expect(liveDay(at: noon(onDay: length + 40)) == nil)
  }

  @Test func liveDayCountsCalendarDaysNotElapsedHours() {
    // 00:05 on day 2 is day 2, even though barely a day has elapsed from a
    // midday start — the trip runs on calendar days (docs/trip-time-model.md).
    let lateStart = Calendar.current.date(
      bySettingHour: 18, minute: 0, second: 0, of: startDate)!
    let justAfterMidnight = Calendar.current.date(
      bySettingHour: 0, minute: 5, second: 0, of: noon(onDay: 2))!
    #expect(liveDay(at: justAfterMidnight, tripStartDate: lateStart) == 2)
  }

  // MARK: - The seeding rule

  @Test func seedingOpensAnUnderwayTripOnItsLiveDay() {
    var seeding = DayLensSeeding()
    #expect(!seeding.hasSeeded)

    #expect(
      seeding.seedDay(now: noon(onDay: 3), tripStartDate: startDate, lengthInDays: length) == 3)
    #expect(seeding.hasSeeded)
  }

  @Test func seedingLeavesTheLensAloneForAnUndatedTrip() {
    var seeding = DayLensSeeding()
    #expect(seeding.seedDay(now: noon(onDay: 2), tripStartDate: nil, lengthInDays: length) == nil)
    #expect(seeding.hasSeeded)
  }

  @Test func seedingLeavesTheLensAloneForAPastOrFutureTrip() {
    var past = DayLensSeeding()
    #expect(
      past.seedDay(now: noon(onDay: length + 2), tripStartDate: startDate, lengthInDays: length)
        == nil)

    var future = DayLensSeeding()
    let beforeTheTrip = Calendar.current.startOfDay(for: startDate).addingTimeInterval(-1)
    #expect(
      future.seedDay(now: beforeTheTrip, tripStartDate: startDate, lengthInDays: length) == nil)
  }

  @Test func seedingHoldsAtTheDayOneAndDayNBoundaries() {
    var first = DayLensSeeding()
    #expect(
      first.seedDay(now: noon(onDay: 1), tripStartDate: startDate, lengthInDays: length) == 1)

    var last = DayLensSeeding()
    #expect(
      last.seedDay(now: noon(onDay: length), tripStartDate: startDate, lengthInDays: length)
        == length)
  }

  @Test func seedingHappensOnlyOnceSoALaterTickNeverOverridesAChoice() {
    var seeding = DayLensSeeding()
    #expect(
      seeding.seedDay(now: noon(onDay: 2), tripStartDate: startDate, lengthInDays: length) == 2)
    // The user has since chosen another day (or "All"); the clock moving on must
    // not move the lens back.
    #expect(
      seeding.seedDay(now: noon(onDay: 3), tripStartDate: startDate, lengthInDays: length) == nil)
  }

  @Test func aDeclinedSeedIsStillSpent() {
    // Opened before the trip started, then the app stayed open into day 1: the
    // lens stays where the user left it rather than jumping on the boundary.
    var seeding = DayLensSeeding()
    let beforeTheTrip = Calendar.current.startOfDay(for: startDate).addingTimeInterval(-1)
    #expect(
      seeding.seedDay(now: beforeTheTrip, tripStartDate: startDate, lengthInDays: length) == nil)
    #expect(
      seeding.seedDay(now: noon(onDay: 1), tripStartDate: startDate, lengthInDays: length) == nil)
  }

  @Test func aSingleDayTripSeedsToItsOnlyDay() {
    var seeding = DayLensSeeding()
    #expect(
      seeding.seedDay(now: noon(onDay: 1), tripStartDate: startDate, lengthInDays: 1) == 1)
  }
}
