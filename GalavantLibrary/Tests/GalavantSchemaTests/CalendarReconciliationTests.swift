import Foundation
import GalavantSchema
import Testing

@Suite struct CalendarReconciliationTests {
  private let calendar = Calendar.current

  private func trip() -> Trip {
    Trip(
      id: UUID(),
      name: "Copenhagen",
      startDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 12)),
      lengthInDays: 3
    )
  }

  private func event(
    title: String,
    day: Int = 1,
    identifier: String = UUID().uuidString
  ) -> CalendarObservedEvent {
    let start = calendar.date(
      byAdding: .day,
      value: day - 1,
      to: calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 19))!
    )!
    return CalendarObservedEvent(
      id: identifier,
      eventIdentifier: identifier,
      title: title,
      startDate: start,
      endDate: start.addingTimeInterval(60 * 60),
      isAllDay: false,
      calendarTitle: "Family"
    )
  }

  private func stop(
    idea: Idea,
    day: Int,
    id: TripIdea.ID = UUID()
  ) -> TripIdea {
    var stop = TripIdea(id: id, tripID: UUID(), ideaID: idea.id, status: .scheduled)
    stop.apply(.day(day))
    return stop
  }

  private func plan(_ stops: [TripIdea], ideas: [Idea]) -> TripPlan {
    TripPlan(
      entries: stops,
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: 3
    )
  }

  @Test func exactMapsIdentityOnTheSameDayIsAutomatic() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 2)
    let input = CalendarIngestedEvent(
      event: event(title: "Dinner reservation", day: 2),
      matchedPlace: CalendarMatchedPlace(name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    )

    let result = CalendarReconciliation.result(for: input, trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))

    guard case let .automatic(match, basis) = result else {
      Issue.record("Expected an automatic Maps-identity match, got \(result).")
      return
    }
    #expect(match.id == stop.id)
    #expect(basis == .mapItemIdentifier)
  }

  @Test func normalizedSameDayNameIsAProposalNotAnAutomaticLink() {
    let noma = Idea(id: UUID(), name: "Noma")
    let stop = stop(idea: noma, day: 1)
    let input = CalendarIngestedEvent(event: event(title: "NÓMA!"))

    let result = CalendarReconciliation.result(for: input, trip: trip(), plan: plan([stop], ideas: [noma]))

    guard case let .proposed(match, basis) = result else {
      Issue.record("Expected a name proposal, got \(result).")
      return
    }
    #expect(match.id == stop.id)
    #expect(basis == .exactName)
  }

  @Test func sameDayNameTiesRemainAmbiguous() {
    let first = Idea(id: UUID(), name: "Noma")
    let second = Idea(id: UUID(), name: "Noma")
    let firstStop = stop(idea: first, day: 1)
    let secondStop = stop(idea: second, day: 1)
    let input = CalendarIngestedEvent(event: event(title: "Noma"))

    let result = CalendarReconciliation.result(
      for: input,
      trip: trip(),
      plan: plan([firstStop, secondStop], ideas: [first, second])
    )

    guard case let .ambiguous(matches) = result else {
      Issue.record("Expected an ambiguous match, got \(result).")
      return
    }
    #expect(Set(matches.map(\.id)) == [firstStop.id, secondStop.id])
  }

  @Test func exactMapsIdentityOnAnotherDayDoesNotMatch() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let input = CalendarIngestedEvent(
      event: event(title: "The French Laundry", day: 2),
      matchedPlace: CalendarMatchedPlace(name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    )

    let result = CalendarReconciliation.result(for: input, trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))

    #expect(result == .unmatched)
  }

  @Test func blankEventTitleNeverManufacturesAMatch() {
    let unnamed = Idea(id: UUID(), name: "")
    let input = CalendarIngestedEvent(event: event(title: ""))

    let result = CalendarReconciliation.result(
      for: input,
      trip: trip(),
      plan: plan([stop(idea: unnamed, day: 1)], ideas: [unnamed])
    )

    #expect(result == .unmatched)
  }
}
