import Foundation
import GalavantSchema
import Testing

@Suite struct StartDaySolverTests {
  /// A stop on `day`, whose idea is closed every `closedOn` weekday, non-food (plain
  /// open/closed check via a bare `.day`).
  private func closedDayStop(
    id: UUID = UUID(), name: String = "Stop", day: Int, closedOn: [Weekday]
  ) -> SolverStop {
    var hours = WeeklyHours.unknown
    for weekday in closedOn { hours[weekday] = .closed }
    return SolverStop(id: id, name: name, schedule: .day(day), weeklyHours: hours, servesMeals: false)
  }

  @Test("The canonical closed-Mondays-on-day-6 case flags only the offending start")
  func closedMondayDaySix() {
    // Day 6 lands on Monday when the trip starts on a Wednesday (Wed + 5 = Mon).
    let stop = closedDayStop(name: "Chez X", day: 6, closedOn: [.monday])
    let options = StartDaySolver.solve(stops: [stop])
    #expect(options.count == 7)

    let wednesdayStart = options.first { $0.startWeekday == .wednesday }!
    #expect(wednesdayStart.conflicts.count == 1)
    #expect(wednesdayStart.conflicts.first?.reason == .closed)
    #expect(wednesdayStart.conflicts.first?.weekday == .monday)
    #expect(wednesdayStart.conflicts.first?.dayNumber == 6)

    // Every other start keeps day 6 off Monday → clean.
    for option in options where option.startWeekday != .wednesday {
      #expect(option.isClean)
    }
  }

  @Test("Meal-aware: a lunch-only weekday conflicts with a wanted-dinner food stop")
  func lunchOnlyVsWantedDinner() {
    var hours = WeeklyHours.unknown
    // Tuesday: lunch service only.
    hours[.tuesday] = .open([ServicePeriod(interval: OpenInterval(open: 12 * 60, close: 14 * 60))])
    // A food stop on day 1, scheduled for dinner.
    let stop = SolverStop(
      id: UUID(), name: "Le Midi", schedule: .daypart(1, .dinner),
      weeklyHours: hours, servesMeals: true
    )
    let options = StartDaySolver.solve(stops: [stop])

    // Start Tuesday → day 1 is Tuesday → open, but no dinner → conflict.
    let tuesday = options.first { $0.startWeekday == .tuesday }!
    #expect(tuesday.conflicts.count == 1)
    #expect(tuesday.conflicts.first?.reason == .notServingMeal(.dinner))

    // A start where day 1 isn't Tuesday doesn't touch the lunch-only day → clean
    // (all other days are unknown).
    let monday = options.first { $0.startWeekday == .monday }!
    #expect(monday.isClean)
  }

  @Test("Meal-aware: the same lunch-only day is fine for a wanted-lunch stop")
  func lunchOnlyVsWantedLunch() {
    var hours = WeeklyHours.unknown
    hours[.tuesday] = .open([ServicePeriod(interval: OpenInterval(open: 12 * 60, close: 14 * 60))])
    let stop = SolverStop(
      id: UUID(), name: "Le Midi", schedule: .timed(1, start: "12:30", end: nil),
      weeklyHours: hours, servesMeals: true
    )
    let tuesday = StartDaySolver.solve(stops: [stop]).first { $0.startWeekday == .tuesday }!
    #expect(tuesday.isClean)
  }

  @Test("Unknown hours never conflict — graceful degradation")
  func unknownNeverConflicts() {
    let foodStop = SolverStop(
      id: UUID(), name: "Mystery", schedule: .daypart(3, .dinner),
      weeklyHours: .unknown, servesMeals: true
    )
    let plainStop = closedDayStop(day: 2, closedOn: [])  // all unknown
    for option in StartDaySolver.solve(stops: [foodStop, plainStop]) {
      #expect(option.isClean)
    }
  }

  @Test("A non-food stop is checked plain open/closed, never as a meal")
  func nonFoodPlainCheck() {
    var hours = WeeklyHours.unknown
    // Museum open Wednesday with a daytime interval; closed Thursday.
    hours[.wednesday] = .open([ServicePeriod(interval: OpenInterval(open: 10 * 60, close: 17 * 60))])
    hours[.thursday] = .closed
    // Scheduled Evening — but it's a museum, so no meal is ever implied.
    let museum = SolverStop(
      id: UUID(), name: "Museum", schedule: .daypart(1, .evening),
      weeklyHours: hours, servesMeals: false
    )
    let options = StartDaySolver.solve(stops: [museum])

    // Start Wednesday → day 1 Wednesday → open → clean (never "no dinner").
    #expect(options.first { $0.startWeekday == .wednesday }!.isClean)
    // Start Thursday → day 1 Thursday → closed → conflict.
    let thursday = options.first { $0.startWeekday == .thursday }!
    #expect(thursday.conflicts.first?.reason == .closed)
  }

  @Test("A bare .day food stop falls back to plain open/closed")
  func bareDayFoodStop() {
    var hours = WeeklyHours.unknown
    hours[.monday] = .closed
    hours[.tuesday] = .open([ServicePeriod(meal: .dinner)])  // dinner only, but no time wanted
    let stop = SolverStop(
      id: UUID(), name: "Anytime Eats", schedule: .day(1),
      weeklyHours: hours, servesMeals: true
    )
    let options = StartDaySolver.solve(stops: [stop])
    // Start Monday → day 1 Monday → closed → conflict.
    #expect(options.first { $0.startWeekday == .monday }!.conflicts.first?.reason == .closed)
    // Start Tuesday → day 1 Tuesday → open (no meal intended) → clean.
    #expect(options.first { $0.startWeekday == .tuesday }!.isClean)
  }

  @Test("Conflict detail reads as an advisory phrase")
  func conflictDetail() {
    let closed = HoursConflict(
      stopID: UUID(), stopName: "Chez X", dayNumber: 6, weekday: .monday, reason: .closed
    )
    #expect(closed.detail == "Day 6 → Chez X: closed Monday")
    let meal = HoursConflict(
      stopID: UUID(), stopName: "Le Midi", dayNumber: 1, weekday: .tuesday,
      reason: .notServingMeal(.dinner)
    )
    #expect(meal.detail == "Day 1 → Le Midi: no dinner")
  }

  @Test("stops(entries:ideasByID:) keeps only scheduled, structured-hours pool stops")
  func stopsBridge() {
    let tripID = UUID()
    let foodID = UUID()
    var foodHours = WeeklyHours.unknown
    foodHours[.monday] = .closed
    let food = Idea(id: foodID, name: "Chez X", kind: .food, structuredHours: foodHours.encoded())
    let noHours = Idea(id: UUID(), name: "No Hours", kind: .food)

    var scheduled = TripIdea(id: UUID(), tripID: tripID, ideaID: foodID, status: .scheduled)
    scheduled.apply(.daypart(2, .dinner))
    // Scheduled but its idea has no structured hours → dropped (doesn't constrain).
    var noHoursStop = TripIdea(id: UUID(), tripID: tripID, ideaID: noHours.id, status: .scheduled)
    noHoursStop.apply(.day(1))
    // A freeform stop (no pool idea) → dropped.
    let freeform = TripIdea.freeform(id: UUID(), tripID: tripID, title: "Lunch break")

    let stops = StartDaySolver.stops(
      entries: [scheduled, noHoursStop, freeform],
      ideasByID: [foodID: food, noHours.id: noHours]
    )
    #expect(stops.count == 1)
    #expect(stops.first?.name == "Chez X")
    #expect(stops.first?.servesMeals == true)
  }
}
