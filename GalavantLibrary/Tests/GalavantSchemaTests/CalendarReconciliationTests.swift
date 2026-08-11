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

  @Test func nearbyDifferentMapsPlacesWithASharedTokenAreProposalOnly() {
    let dichter = Idea(
      id: UUID(),
      name: "Dichter",
      latitude: 47.698_000,
      longitude: 11.763_000,
      mapItemIdentifier: "maps-venue")
    let stop = stop(idea: dichter, day: 1)
    let input = CalendarIngestedEvent(
      event: CalendarObservedEvent(
        id: "reservation-1",
        eventIdentifier: "reservation-1",
        title: "Dinner Dichter",
        latitude: 47.698_350,
        longitude: 11.763_350,
        startDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 19))!,
        endDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 20))!,
        isAllDay: false,
        calendarTitle: "Family"),
      matchedPlace: CalendarMatchedPlace(name: "Gourmetrestaurant Dichter", mapItemIdentifier: "maps-address"))

    let candidates = CalendarReconciliation.candidates(
      for: [input], trip: trip(), plan: plan([stop], ideas: [dichter]))
    guard case let .proposed(match, basis) = candidates.first?.result else {
      Issue.record("Expected a nearby, differently resolved Maps place to be proposed.")
      return
    }
    #expect(match.id == stop.id)
    #expect(basis == .nameAndProximity)

    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates,
      localState: CalendarReconciliationLocalState(),
      observedAt: .distantPast,
      makeHistoryID: UUID.init)
    #expect(automaticPlan.applications.isEmpty)
    #expect(automaticPlan.localState == CalendarReconciliationLocalState())
  }

  @Test func nameOverlapWithoutCoordinatesDoesNotBecomeAProposal() {
    let dichter = Idea(id: UUID(), name: "Dichter", mapItemIdentifier: "maps-venue")
    let stop = stop(idea: dichter, day: 1)
    let input = CalendarIngestedEvent(
      event: event(title: "Dinner Dichter", identifier: "reservation-1"),
      matchedPlace: CalendarMatchedPlace(name: "Gourmetrestaurant Dichter", mapItemIdentifier: "maps-address"))

    let result = CalendarReconciliation.result(
      for: input, trip: trip(), plan: plan([stop], ideas: [dichter]))

    #expect(result == .unmatched)
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

  @Test func sameDayEventWithoutAMatchingStopIsUnmatched() {
    let noma = Idea(id: UUID(), name: "Noma")
    let input = CalendarIngestedEvent(event: event(title: "Canal tour"))

    let result = CalendarReconciliation.result(
      for: input,
      trip: trip(),
      plan: plan([stop(idea: noma, day: 1)], ideas: [noma])
    )

    #expect(result == .unmatched)
  }

  @Test func sameDayMapsIdentityTieRemainsAmbiguous() {
    let first = Idea(id: UUID(), name: "Noma", mapItemIdentifier: "maps-noma")
    let second = Idea(id: UUID(), name: "Noma Upstairs", mapItemIdentifier: "maps-noma")
    let firstStop = stop(idea: first, day: 1)
    let secondStop = stop(idea: second, day: 1)
    let input = CalendarIngestedEvent(
      event: event(title: "Noma"),
      matchedPlace: CalendarMatchedPlace(name: "Noma", mapItemIdentifier: "maps-noma")
    )

    let result = CalendarReconciliation.result(
      for: input,
      trip: trip(),
      plan: plan([firstStop, secondStop], ideas: [first, second])
    )

    guard case let .ambiguous(matches) = result else {
      Issue.record("Expected an ambiguous Maps-identity match, got \(result).")
      return
    }
    #expect(Set(matches.map(\.id)) == [firstStop.id, secondStop.id])
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

  @Test func uniqueMapsMatchLinksAndRecordsLocalHistory() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let input = CalendarIngestedEvent(
      event: event(title: "Dinner", identifier: "reservation-1"),
      matchedPlace: CalendarMatchedPlace(name: frenchLaundry.name, mapItemIdentifier: frenchLaundry.mapItemIdentifier)
    )
    let candidates = CalendarReconciliation.candidates(
      for: [input], trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))

    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates,
      localState: CalendarReconciliationLocalState(),
      observedAt: Date(timeIntervalSince1970: 1), makeHistoryID: UUID.init)

    #expect(automaticPlan.applications.map(\.stopID) == [stop.id])
    #expect(automaticPlan.applications.map(\.kind) == [.linked])
    #expect(automaticPlan.localState.authority(for: stop.id) == .linked)
    #expect(automaticPlan.localState.history.map(\.kind) == [.linked])
  }

  @Test func identicalLinkedObservationDoesNotCreateAnotherHistoryEntry() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let input = CalendarIngestedEvent(
      event: event(title: "Dinner", identifier: "reservation-1"),
      matchedPlace: CalendarMatchedPlace(name: frenchLaundry.name, mapItemIdentifier: frenchLaundry.mapItemIdentifier)
    )
    let candidates = CalendarReconciliation.candidates(
      for: [input], trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))
    let first = CalendarReconciliation.automaticPlan(
      candidates: candidates, localState: CalendarReconciliationLocalState(), observedAt: .distantPast,
      makeHistoryID: UUID.init)

    let second = CalendarReconciliation.automaticPlan(
      candidates: candidates, localState: first.localState, observedAt: .distantFuture, makeHistoryID: UUID.init)

    #expect(second.applications.isEmpty)
    #expect(second.localState == first.localState)
  }

  @Test func linkedEventMovingDaysUpdatesWithoutRematchingByDay() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let initial = CalendarIngestedEvent(
      event: event(title: "Dinner", identifier: "reservation-1"),
      matchedPlace: CalendarMatchedPlace(name: frenchLaundry.name, mapItemIdentifier: frenchLaundry.mapItemIdentifier)
    )
    let initialCandidates = CalendarReconciliation.candidates(
      for: [initial], trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))
    let initialPlan = CalendarReconciliation.automaticPlan(
      candidates: initialCandidates, localState: CalendarReconciliationLocalState(), observedAt: .distantPast,
      makeHistoryID: UUID.init)

    let moved = CalendarIngestedEvent(
      event: event(title: "Dinner", day: 2, identifier: "reservation-1"),
      matchedPlace: CalendarMatchedPlace(name: frenchLaundry.name, mapItemIdentifier: frenchLaundry.mapItemIdentifier)
    )
    let movedCandidates = CalendarReconciliation.candidates(
      for: [moved], trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))
    #expect(movedCandidates.first?.result == .unmatched)

    let updatedPlan = CalendarReconciliation.automaticPlan(
      candidates: movedCandidates, localState: initialPlan.localState, observedAt: .distantFuture,
      makeHistoryID: UUID.init)

    #expect(updatedPlan.applications.map(\.stopID) == [stop.id])
    #expect(updatedPlan.applications.map(\.kind) == [.updated])
    #expect(updatedPlan.localState.history.map(\.kind) == [.linked, .updated])
  }

  @Test func namedProposalAndMissingLinkedEventNeverWriteOrInferDeletion() {
    let noma = Idea(id: UUID(), name: "Noma")
    let stop = stop(idea: noma, day: 1)
    let proposed = CalendarIngestedEvent(event: event(title: "Noma", identifier: "proposal"))
    let proposedCandidates = CalendarReconciliation.candidates(
      for: [proposed], trip: trip(), plan: plan([stop], ideas: [noma]))

    let proposalPlan = CalendarReconciliation.automaticPlan(
      candidates: proposedCandidates, localState: CalendarReconciliationLocalState(), observedAt: .distantPast,
      makeHistoryID: UUID.init)
    #expect(proposalPlan.applications.isEmpty)
    #expect(proposalPlan.localState == CalendarReconciliationLocalState())

    let linkedState = CalendarReconciliationLocalState(
      linkedStops: [
        CalendarLinkedStop(
          stopID: stop.id,
          eventID: "reservation-1",
          commitment: .allDay(date: .distantPast),
          observedAt: .distantPast)
      ])
    let absentPlan = CalendarReconciliation.automaticPlan(
      candidates: [], localState: linkedState, observedAt: .distantFuture, makeHistoryID: UUID.init)
    #expect(absentPlan.applications.isEmpty)
    #expect(absentPlan.localState == linkedState)
  }

  @Test func linkedEventMovedOutsideTripIsRecordedWithoutChangingTheStop() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let initial = CalendarIngestedEvent(
      event: event(title: "Dinner", identifier: "reservation-1"),
      matchedPlace: CalendarMatchedPlace(name: frenchLaundry.name, mapItemIdentifier: frenchLaundry.mapItemIdentifier))
    let initialCandidates = CalendarReconciliation.candidates(
      for: [initial], trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))
    let linkedPlan = CalendarReconciliation.automaticPlan(
      candidates: initialCandidates,
      localState: CalendarReconciliationLocalState(),
      observedAt: .distantPast,
      makeHistoryID: UUID.init)

    let outsideEvent = event(title: "Dinner", day: -7, identifier: "changed-event-identifier")
    let movedPlan = CalendarReconciliation.automaticPlan(
      candidates: [],
      outsideTripObservations: [
        CalendarBoundEventObservation(bindingID: "reservation-1", event: outsideEvent)
      ],
      localState: linkedPlan.localState,
      observedAt: .distantFuture,
      makeHistoryID: UUID.init)

    #expect(movedPlan.applications.isEmpty)
    #expect(movedPlan.localState.linkedStops.first?.commitment == linkedPlan.localState.linkedStops.first?.commitment)
    #expect(movedPlan.localState.linkedStops.first?.movedOutsideTripCommitment == CalendarCommitment(event: outsideEvent))
    #expect(movedPlan.localState.history.map(\.kind) == [.linked, .movedOutsideTrip])
  }

  @Test func repeatedOutsideTripObservationDoesNotCreateDuplicateHistory() {
    let linked = CalendarLinkedStop(
      stopID: UUID(),
      eventID: "reservation-1",
      commitment: .allDay(date: .distantPast),
      observedAt: .distantPast)
    let outsideEvent = event(title: "Dinner", day: -7, identifier: "new-event-identifier")
    let first = CalendarReconciliation.automaticPlan(
      candidates: [],
      outsideTripObservations: [CalendarBoundEventObservation(bindingID: linked.eventID, event: outsideEvent)],
      localState: CalendarReconciliationLocalState(linkedStops: [linked]),
      observedAt: .distantPast,
      makeHistoryID: UUID.init)
    let second = CalendarReconciliation.automaticPlan(
      candidates: [],
      outsideTripObservations: [CalendarBoundEventObservation(bindingID: linked.eventID, event: outsideEvent)],
      localState: first.localState,
      observedAt: .distantFuture,
      makeHistoryID: UUID.init)

    #expect(second.applications.isEmpty)
    #expect(second.localState == first.localState)
  }

  @Test func twoAutomaticEventsForOneStopStayUnlinked() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let inputs = ["first", "second"].map {
      CalendarIngestedEvent(
        event: event(title: "Dinner", identifier: $0),
        matchedPlace: CalendarMatchedPlace(name: frenchLaundry.name, mapItemIdentifier: frenchLaundry.mapItemIdentifier))
    }
    let candidates = CalendarReconciliation.candidates(
      for: inputs, trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))

    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates, localState: CalendarReconciliationLocalState(), observedAt: .distantPast,
      makeHistoryID: UUID.init)

    #expect(automaticPlan.applications.isEmpty)
    #expect(automaticPlan.localState == CalendarReconciliationLocalState())
  }

  @Test func crossDayTimedEventWaitsForTheTemporalSlice() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let overnight = event(title: "Dinner", identifier: "overnight")
    let input = CalendarIngestedEvent(
      event: CalendarObservedEvent(
        id: overnight.id,
        eventIdentifier: overnight.eventIdentifier,
        title: overnight.title,
        startDate: overnight.startDate,
        endDate: calendar.date(byAdding: .day, value: 1, to: overnight.endDate)!,
        isAllDay: false,
        calendarTitle: overnight.calendarTitle),
      matchedPlace: CalendarMatchedPlace(name: frenchLaundry.name, mapItemIdentifier: frenchLaundry.mapItemIdentifier))
    let candidates = CalendarReconciliation.candidates(
      for: [input], trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))

    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates, localState: CalendarReconciliationLocalState(), observedAt: .distantPast,
      makeHistoryID: UUID.init)

    #expect(automaticPlan.applications.isEmpty)
    #expect(automaticPlan.localState == CalendarReconciliationLocalState())
  }

  @Test func displayFallbackIdentityCannotEstablishALink() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let fallback = event(title: "Dinner")
    let input = CalendarIngestedEvent(
      event: CalendarObservedEvent(
        id: "display-only",
        hasStableLocalIdentity: false,
        title: "Dinner",
        startDate: fallback.startDate,
        endDate: fallback.endDate,
        isAllDay: false,
        calendarTitle: "Family"),
      matchedPlace: CalendarMatchedPlace(name: frenchLaundry.name, mapItemIdentifier: frenchLaundry.mapItemIdentifier))
    let candidates = CalendarReconciliation.candidates(
      for: [input], trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))

    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates, localState: CalendarReconciliationLocalState(), observedAt: .distantPast,
      makeHistoryID: UUID.init)

    #expect(automaticPlan.applications.isEmpty)
    #expect(automaticPlan.localState == CalendarReconciliationLocalState())
  }
}
