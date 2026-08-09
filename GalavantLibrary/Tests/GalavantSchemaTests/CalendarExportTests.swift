import Foundation
import GalavantSchema
import Testing

/// `TripPlan.calendarExportItems` is the pure functional core behind the
/// calendar-export feature (BACKLOG "Export itinerary to Apple Calendar /
/// iCal"): a dated trip's `.timed`/`.daypart`/`.day` scheduled stops resolved to
/// concrete start/end `Date`s, no EventKit or database in sight.
@Suite struct CalendarExportTests {
  // The production code (`TripPlan.calendarExportItems`) derives dates with
  // `Calendar.current`, so assertions extract components with the same
  // calendar — a fixed/UTC calendar here would drift from production by the
  // host's UTC offset. Noon avoids any same-day boundary ambiguity.
  static let calendar = Calendar.current

  func trip(
    startDate: Date? = CalendarExportTests.calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 12)),
    lengthInDays: Int = 5
  ) -> Trip {
    Trip(id: UUID(), name: "Copenhagen", startDate: startDate, lengthInDays: lengthInDays)
  }

  func idea(_ id: Idea.ID = UUID(), name: String = "Tivoli", notes: String = "", description: String = "") -> Idea {
    Idea(id: id, name: name, description: description, notes: notes)
  }

  func entry(idea ideaID: Idea.ID, schedule: Schedule) -> TripIdea {
    var e = TripIdea(id: UUID(), tripID: UUID(), ideaID: ideaID, status: .scheduled)
    e.apply(schedule)
    return e
  }

  func plan(_ entries: [TripIdea], ideas: [Idea], lengthInDays: Int = 5) -> TripPlan {
    TripPlan(
      entries: entries,
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: lengthInDays
    )
  }

  @Test func undatedTripExportsNothing() {
    let ideaA = idea()
    let entries = [entry(idea: ideaA.id, schedule: .day(1))]
    let p = plan(entries, ideas: [ideaA])
    #expect(p.calendarExportItems(trip: trip(startDate: nil)).isEmpty)
  }

  @Test func dayScheduleExportsAllDayEvent() {
    let ideaA = idea()
    let entries = [entry(idea: ideaA.id, schedule: .day(3))]  // day 3 = Aug 3
    let p = plan(entries, ideas: [ideaA])
    let items = p.calendarExportItems(trip: trip())
    #expect(items.count == 1)
    let item = items[0]
    #expect(item.isAllDay)
    #expect(item.title == "Tivoli")
    let comps = Self.calendar.dateComponents([.year, .month, .day], from: item.start)
    #expect(comps.year == 2026 && comps.month == 8 && comps.day == 3)
    // All-day convention: end is the next midnight.
    let endComps = Self.calendar.dateComponents([.year, .month, .day], from: item.end)
    #expect(endComps.day == 4)
  }

  @Test func daypartScheduleAnchorsAtSortHourWithSynthesizedDuration() {
    let ideaA = idea()
    let entries = [entry(idea: ideaA.id, schedule: .daypart(2, .dinner))]  // day 2, dinner sortHour 18
    let p = plan(entries, ideas: [ideaA])
    let item = p.calendarExportItems(trip: trip())[0]
    #expect(!item.isAllDay)
    let startComps = Self.calendar.dateComponents([.day, .hour, .minute], from: item.start)
    #expect(startComps.day == 2 && startComps.hour == 18 && startComps.minute == 0)
    let duration = item.end.timeIntervalSince(item.start)
    #expect(duration == Double(TripPlan.daypartExportDurationMinutes * 60))
  }

  @Test func timedScheduleWithExplicitEndUsesIt() {
    let ideaA = idea()
    let entries = [entry(idea: ideaA.id, schedule: .timed(1, start: "09:30", end: "11:00"))]
    let p = plan(entries, ideas: [ideaA])
    let item = p.calendarExportItems(trip: trip())[0]
    #expect(!item.isAllDay)
    let start = Self.calendar.dateComponents([.day, .hour, .minute], from: item.start)
    let end = Self.calendar.dateComponents([.day, .hour, .minute], from: item.end)
    #expect(start.day == 1 && start.hour == 9 && start.minute == 30)
    #expect(end.day == 1 && end.hour == 11 && end.minute == 0)
  }

  @Test func timedScheduleWithoutEndDefaultsToSuggestedGap() {
    let ideaA = idea()
    let entries = [entry(idea: ideaA.id, schedule: .timed(1, start: "09:30", end: nil))]
    let p = plan(entries, ideas: [ideaA])
    let item = p.calendarExportItems(trip: trip())[0]
    let duration = item.end.timeIntervalSince(item.start)
    #expect(duration == Double(Schedule.suggestedGapMinutes * 60))
  }

  @Test func notesPreferIdeaNotesThenDescriptionThenNil() {
    let withNotes = idea(name: "A", notes: "Bring cash", description: "A description")
    let withDescriptionOnly = idea(name: "B", notes: "", description: "A description")
    let withNeither = idea(name: "C", notes: "", description: "")
    let entries = [
      entry(idea: withNotes.id, schedule: .day(1)),
      entry(idea: withDescriptionOnly.id, schedule: .day(1)),
      entry(idea: withNeither.id, schedule: .day(1)),
    ]
    let p = plan(entries, ideas: [withNotes, withDescriptionOnly, withNeither])
    let items = p.calendarExportItems(trip: trip())
    func notes(for title: String) -> String? { items.first { $0.title == title }?.notes }
    #expect(notes(for: "A") == "Bring cash")
    #expect(notes(for: "B") == "A description")
    #expect(notes(for: "C") == nil)
  }

  @Test func freeformStopUsesInlineNoteAndTitle() {
    var freeform = TripIdea.freeform(
      id: UUID(), tripID: UUID(), title: "Train to Aarhus", note: "Platform 4")
    freeform.apply(.timed(1, start: "08:00", end: nil))
    let p = plan([freeform], ideas: [])
    let item = p.calendarExportItems(trip: trip())[0]
    #expect(item.title == "Train to Aarhus")
    #expect(item.notes == "Platform 4")
  }

  @Test func unscheduledEntryNeverReachesTheItineraryProjection() {
    // Belt-and-suspenders: `itinerary` already filters to scheduled+dayed stops,
    // so `calendarExportItems` should never see (and would skip) an unscheduled
    // one if it somehow did.
    let ideaA = idea()
    let entries = [entry(idea: ideaA.id, schedule: .unscheduled)]
    let p = plan(entries, ideas: [ideaA])
    #expect(p.calendarExportItems(trip: trip()).isEmpty)
  }

  @Test func multiDayTripOrdersItemsByDayThenIntraDay() {
    let (a, b, c) = (idea(name: "A"), idea(name: "B"), idea(name: "C"))
    let entries = [
      entry(idea: a.id, schedule: .timed(2, start: "10:00", end: nil)),
      entry(idea: b.id, schedule: .timed(1, start: "14:00", end: nil)),
      entry(idea: c.id, schedule: .timed(1, start: "09:00", end: nil)),
    ]
    let p = plan(entries, ideas: [a, b, c])
    let items = p.calendarExportItems(trip: trip())
    // Day 1's two timed stops sort 09:00 before 14:00; day 2's stop comes last.
    #expect(items.map(\.title) == ["C", "B", "A"])
  }
}
