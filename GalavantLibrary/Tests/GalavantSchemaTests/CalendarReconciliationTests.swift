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
    identifier: String = UUID().uuidString,
    externalIdentifier: String? = "server-item",
    isAllDay: Bool = false,
    isRecurring: Bool = false
  ) -> CalendarObservedEvent {
    let start = calendar.date(
      byAdding: .day,
      value: day - 1,
      to: calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 19))!
    )!
    return CalendarObservedEvent(
      id: identifier,
      eventIdentifier: identifier,
      externalIdentifier: externalIdentifier,
      title: title,
      startDate: start,
      endDate: start.addingTimeInterval(60 * 60),
      isAllDay: isAllDay,
      isRecurring: isRecurring,
      calendarTitle: "Family"
    )
  }

  private func ingestedEvent(
    event: CalendarObservedEvent,
    matchedPlace: CalendarMatchedPlace? = nil,
    itineraryTimeZone: TimeZone? = nil
  ) -> CalendarIngestedEvent {
    CalendarIngestedEvent(
      event: event,
      matchedPlace: matchedPlace,
      itineraryTimeZone: itineraryTimeZone ?? calendar.timeZone)
  }

  /// An automatic Maps-identity candidate for `stop`, the shape that drives a link.
  private func mapsMatchCandidate(
    for stop: TripIdea, idea: Idea, event: CalendarObservedEvent
  ) -> [CalendarReconciliationCandidate] {
    let input = ingestedEvent(
      event: event,
      matchedPlace: CalendarMatchedPlace(name: idea.name, mapItemIdentifier: idea.mapItemIdentifier))
    return CalendarReconciliation.candidates(for: [input], trip: trip(), plan: plan([stop], ideas: [idea]))
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
    let input = ingestedEvent(
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

  @Test func absoluteEventMatchesTheTripDayInTheItineraryZone() throws {
    let newYork = try #require(TimeZone(identifier: "America/New_York"))
    let rome = try #require(TimeZone(identifier: "Europe/Rome"))
    var newYorkCalendar = Calendar(identifier: .gregorian)
    newYorkCalendar.timeZone = newYork
    var romeCalendar = Calendar(identifier: .gregorian)
    romeCalendar.timeZone = rome
    let trip = Trip(
      id: UUID(), name: "Rome",
      startDate: romeCalendar.date(from: DateComponents(
        year: 2026, month: 8, day: 12)),
      lengthInDays: 3)
    let idea = Idea(
      id: UUID(), name: "Late reservation",
      mapItemIdentifier: "maps-late-reservation")
    let stop = stop(idea: idea, day: 1)
    let start = try #require(newYorkCalendar.date(from: DateComponents(
      year: 2026, month: 8, day: 11, hour: 22)))
    let observed = CalendarObservedEvent(
      id: "reservation-1",
      eventIdentifier: "reservation-1",
      externalIdentifier: "server-item",
      title: "Late reservation",
      temporal: .absolute(
        start: start,
        end: start.addingTimeInterval(60 * 60),
        timeZone: newYork),
      calendarTitle: "Family")
    let input = CalendarIngestedEvent(
      event: observed,
      matchedPlace: CalendarMatchedPlace(
        name: idea.name, mapItemIdentifier: idea.mapItemIdentifier),
      itineraryTimeZone: rome)

    let candidates = CalendarReconciliation.candidates(
      for: [input], trip: trip, plan: plan([stop], ideas: [idea]))
    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates,
      localState: CalendarReconciliationLocalState(),
      observedAt: .distantPast,
      makeHistoryID: UUID.init)

    #expect(candidates.first?.projection.dayNumber == 1)
    #expect(automaticPlan.applications.first?.dayNumber == 1)
    #expect(automaticPlan.applications.first?.stopID == stop.id)
  }

  @Test func absoluteEventWithoutItineraryZoneRemainsAReconciliationItem() {
    let input = CalendarIngestedEvent(event: event(title: "Call Tax Advisor"))

    let candidates = CalendarReconciliation.candidates(
      for: [input], trip: trip(), plan: plan([], ideas: []))

    #expect(candidates.first?.result == .unresolvedTimeZone)
    #expect(candidates.first?.projection == .unresolvedTimeZone)
  }

  @Test func legacyLocalBindingDecodesWithoutHealingMetadata() throws {
    struct LegacyLinkedStop: Codable {
      var stopID: TripIdea.ID
      var eventID: String
      var commitment: CalendarCommitment
      var observedAt: Date
      var eventTitle: String?
      var movedOutsideTripCommitment: CalendarCommitment?
    }
    struct LegacyState: Codable {
      var linkedStops: [LegacyLinkedStop]
      var history: [CalendarReconciliationHistoryEntry]
    }
    let legacy = LegacyState(
      linkedStops: [LegacyLinkedStop(
        stopID: UUID(), eventID: "old-id",
        commitment: .allDay(date: .distantPast),
        observedAt: .distantPast,
        eventTitle: "Dinner",
        movedOutsideTripCommitment: nil)],
      history: [])

    let decoded = try JSONDecoder().decode(
      CalendarReconciliationLocalState.self,
      from: JSONEncoder().encode(legacy))

    #expect(decoded.linkedStops.first?.sourceExternalIdentifier == nil)
    #expect(decoded.linkedStops.first?.occurrenceAnchor == nil)
    #expect(decoded.linkedStops.first?.itineraryTimeZoneIdentifier == nil)
  }

  @Test func normalizedSameDayNameIsAProposalNotAnAutomaticLink() {
    let noma = Idea(id: UUID(), name: "Noma")
    let stop = stop(idea: noma, day: 1)
    let input = ingestedEvent(event: event(title: "NÓMA!"))

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
    let input = ingestedEvent(
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
    let input = ingestedEvent(
      event: event(title: "Dinner Dichter", identifier: "reservation-1"),
      matchedPlace: CalendarMatchedPlace(name: "Gourmetrestaurant Dichter", mapItemIdentifier: "maps-address"))

    let result = CalendarReconciliation.result(
      for: input, trip: trip(), plan: plan([stop], ideas: [dichter]))

    #expect(result == .unmatched)
  }

  @Test func nearbyNameMatchBeyondOneHundredMetersIsUnmatched() {
    let dichter = Idea(
      id: UUID(),
      name: "Dichter",
      latitude: 47.698_000,
      longitude: 11.763_000,
      mapItemIdentifier: "maps-venue")
    let stop = stop(idea: dichter, day: 1)
    let input = ingestedEvent(
      event: CalendarObservedEvent(
        id: "reservation-1",
        eventIdentifier: "reservation-1",
        title: "Dinner Dichter",
        latitude: 47.700_000,
        longitude: 11.763_000,
        startDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 19))!,
        endDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 20))!,
        isAllDay: false,
        calendarTitle: "Family"),
      matchedPlace: CalendarMatchedPlace(name: "Gourmetrestaurant Dichter", mapItemIdentifier: "maps-address"))

    let result = CalendarReconciliation.result(
      for: input, trip: trip(), plan: plan([stop], ideas: [dichter]))

    #expect(result == .unmatched)
  }

  @Test func nearbyNameMatchTieRemainsAmbiguous() {
    let first = Idea(
      id: UUID(),
      name: "Dichter Restaurant",
      latitude: 47.698_000,
      longitude: 11.763_000,
      mapItemIdentifier: "maps-venue-1")
    let second = Idea(
      id: UUID(),
      name: "Dichter Bar",
      latitude: 47.698_300,
      longitude: 11.763_300,
      mapItemIdentifier: "maps-venue-2")
    let firstStop = stop(idea: first, day: 1)
    let secondStop = stop(idea: second, day: 1)
    let input = ingestedEvent(
      event: CalendarObservedEvent(
        id: "reservation-1",
        eventIdentifier: "reservation-1",
        title: "Dinner Dichter",
        latitude: 47.698_150,
        longitude: 11.763_150,
        startDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 19))!,
        endDate: calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 20))!,
        isAllDay: false,
        calendarTitle: "Family"),
      matchedPlace: CalendarMatchedPlace(name: "Gourmetrestaurant Dichter", mapItemIdentifier: "maps-address"))

    let result = CalendarReconciliation.result(
      for: input,
      trip: trip(),
      plan: plan([firstStop, secondStop], ideas: [first, second]))

    guard case let .ambiguous(matches) = result else {
      Issue.record("Expected nearby place tie to remain ambiguous.")
      return
    }
    #expect(Set(matches.map(\.id)) == [firstStop.id, secondStop.id])
  }

  @Test func sameDayNameTiesRemainAmbiguous() {
    let first = Idea(id: UUID(), name: "Noma")
    let second = Idea(id: UUID(), name: "Noma")
    let firstStop = stop(idea: first, day: 1)
    let secondStop = stop(idea: second, day: 1)
    let input = ingestedEvent(event: event(title: "Noma"))

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
    let input = ingestedEvent(
      event: event(title: "The French Laundry", day: 2),
      matchedPlace: CalendarMatchedPlace(name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    )

    let result = CalendarReconciliation.result(for: input, trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))

    #expect(result == .unmatched)
  }

  @Test func sameDayEventWithoutAMatchingStopIsUnmatched() {
    let noma = Idea(id: UUID(), name: "Noma")
    let input = ingestedEvent(event: event(title: "Canal tour"))

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
    let input = ingestedEvent(
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
    let input = ingestedEvent(event: event(title: ""))

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
    let input = ingestedEvent(
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

  @Test func localCalendarEventIsShownButNeverWritesTheSharedPlan() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    // A device-only calendar event: no server identity, but an otherwise perfect
    // automatic Maps match. It must stay a candidate yet never bind, apply, or sync.
    let candidates = mapsMatchCandidate(
      for: stop, idea: frenchLaundry,
      event: event(title: "Dinner", identifier: "reservation-1", externalIdentifier: nil))
    #expect({ if case .automatic = candidates.first?.result { true } else { false } }())

    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates, localState: CalendarReconciliationLocalState(), observedAt: .distantPast,
      makeHistoryID: UUID.init)

    #expect(automaticPlan.applications.isEmpty)
    #expect(automaticPlan.localState == CalendarReconciliationLocalState())
  }

  @Test func allDayEventLinksAsCivilDayContext() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    // Slice 4 captures the civil range before it can be flattened through a
    // device zone, so it can now establish the same shared fact on both phones.
    let candidates = mapsMatchCandidate(
      for: stop, idea: frenchLaundry,
      event: event(title: "Dinner", identifier: "reservation-1", isAllDay: true))

    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates, localState: CalendarReconciliationLocalState(), observedAt: .distantPast,
      makeHistoryID: UUID.init)

    #expect(automaticPlan.applications.map(\.stopID) == [stop.id])
    #expect(automaticPlan.applications.first?.commitment.occupancy == .dayContext)
    #expect(automaticPlan.localState.authority(for: stop.id) == .linked)
  }

  @Test func recurringOccurrenceLinksWithoutBindingTheWholeSeries() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    // The occurrence's original scheduled start now disambiguates the series ID.
    let candidates = mapsMatchCandidate(
      for: stop, idea: frenchLaundry,
      event: event(title: "Dinner", identifier: "reservation-1", isRecurring: true))

    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates, localState: CalendarReconciliationLocalState(), observedAt: .distantPast,
      makeHistoryID: UUID.init)

    #expect(automaticPlan.applications.map(\.stopID) == [stop.id])
    #expect(automaticPlan.localState.authority(for: stop.id) == .linked)
  }

  @Test func anIneligibleDuplicateDoesNotBlockAnEligibleAutomaticLink() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let match = CalendarMatchedPlace(name: frenchLaundry.name, mapItemIdentifier: frenchLaundry.mapItemIdentifier)
    // Two automatic matches for one stop, but only one has a server identity. The
    // device-only copy must not manufacture ambiguity that suppresses the real link.
    let eligible = ingestedEvent(
      event: event(title: "Dinner", identifier: "reservation-1"), matchedPlace: match)
    let ineligible = ingestedEvent(
      event: event(
        title: "Dinner", identifier: "reservation-2", externalIdentifier: nil),
      matchedPlace: match)
    let candidates = CalendarReconciliation.candidates(
      for: [eligible, ineligible], trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))

    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates, localState: CalendarReconciliationLocalState(), observedAt: .distantPast,
      makeHistoryID: UUID.init)

    #expect(automaticPlan.applications.map(\.stopID) == [stop.id])
    #expect(automaticPlan.applications.map(\.kind) == [.linked])
  }

  @Test func identicalLinkedObservationDoesNotCreateAnotherHistoryEntry() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let input = ingestedEvent(
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
    let initial = ingestedEvent(
      event: event(title: "Dinner", identifier: "reservation-1"),
      matchedPlace: CalendarMatchedPlace(name: frenchLaundry.name, mapItemIdentifier: frenchLaundry.mapItemIdentifier)
    )
    let initialCandidates = CalendarReconciliation.candidates(
      for: [initial], trip: trip(), plan: plan([stop], ideas: [frenchLaundry]))
    let initialPlan = CalendarReconciliation.automaticPlan(
      candidates: initialCandidates, localState: CalendarReconciliationLocalState(), observedAt: .distantPast,
      makeHistoryID: UUID.init)

    let moved = ingestedEvent(
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

  @Test func detachedOccurrenceHealsChangedEventIdentifierAndAppliesMove() throws {
    let idea = Idea(
      id: UUID(), name: "The French Laundry",
      mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: idea, day: 1)
    let originalStart = try #require(calendar.date(from: DateComponents(
      year: 2026, month: 8, day: 1, hour: 19)))
    let occurrence = CalendarOccurrenceAnchor.absolute(originalStart)
    let original = CalendarObservedEvent(
      id: "old-local-id",
      eventIdentifier: "old-local-id",
      externalIdentifier: "server-series",
      title: "Dinner",
      temporal: .absolute(
        start: originalStart,
        end: originalStart.addingTimeInterval(60 * 60),
        timeZone: calendar.timeZone),
      recurrence: CalendarEventRecurrence(
        originalOccurrence: occurrence, isDetached: false),
      calendarTitle: "Family")
    let match = CalendarMatchedPlace(
      name: idea.name, mapItemIdentifier: idea.mapItemIdentifier)
    let initialCandidates = CalendarReconciliation.candidates(
      for: [ingestedEvent(event: original, matchedPlace: match)],
      trip: trip(),
      plan: plan([stop], ideas: [idea]))
    let initialPlan = CalendarReconciliation.automaticPlan(
      candidates: initialCandidates,
      localState: CalendarReconciliationLocalState(),
      observedAt: .distantPast,
      makeHistoryID: UUID.init)

    let movedStart = try #require(calendar.date(
      byAdding: .day, value: 1, to: originalStart))
    let detached = CalendarObservedEvent(
      id: "new-local-id",
      eventIdentifier: "new-local-id",
      externalIdentifier: "server-series",
      title: "Dinner",
      temporal: .absolute(
        start: movedStart,
        end: movedStart.addingTimeInterval(60 * 60),
        timeZone: calendar.timeZone),
      recurrence: CalendarEventRecurrence(
        originalOccurrence: occurrence, isDetached: true),
      calendarTitle: "Family")
    let movedCandidates = CalendarReconciliation.candidates(
      for: [ingestedEvent(event: detached, matchedPlace: match)],
      trip: trip(),
      plan: plan([stop], ideas: [idea]))
    let updatedPlan = CalendarReconciliation.automaticPlan(
      candidates: movedCandidates,
      localState: initialPlan.localState,
      observedAt: .distantFuture,
      makeHistoryID: UUID.init)

    #expect(updatedPlan.localState.linkedStops.first?.eventID == "new-local-id")
    #expect(updatedPlan.localState.linkedStops.first?.occurrenceAnchor == occurrence)
    #expect(updatedPlan.applications.first?.kind == .updated)
    #expect(updatedPlan.applications.first?.dayNumber == 2)
  }

  @Test func namedProposalAndMissingLinkedEventNeverWriteOrInferDeletion() {
    let noma = Idea(id: UUID(), name: "Noma")
    let stop = stop(idea: noma, day: 1)
    let proposed = ingestedEvent(event: event(title: "Noma", identifier: "proposal"))
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
    let initial = ingestedEvent(
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
      ingestedEvent(
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

  @Test func crossDayTimedEventIsPreservedByTheTemporalSlice() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let overnight = event(title: "Dinner", identifier: "overnight")
    let input = ingestedEvent(
      event: CalendarObservedEvent(
        id: overnight.id,
        eventIdentifier: overnight.eventIdentifier,
        externalIdentifier: overnight.externalIdentifier,
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

    #expect(automaticPlan.applications.map(\.stopID) == [stop.id])
    #expect(automaticPlan.localState.authority(for: stop.id) == .linked)
  }

  @Test func displayFallbackIdentityCannotEstablishALink() {
    let frenchLaundry = Idea(id: UUID(), name: "The French Laundry", mapItemIdentifier: "maps-french-laundry")
    let stop = stop(idea: frenchLaundry, day: 1)
    let fallback = event(title: "Dinner")
    let input = ingestedEvent(
      event: CalendarObservedEvent(
        id: "display-only",
        hasStableLocalIdentity: false,
        externalIdentifier: "server-item",
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
