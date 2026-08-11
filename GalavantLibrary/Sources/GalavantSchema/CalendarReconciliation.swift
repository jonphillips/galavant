import Foundation

/// A value snapshot of an EventKit event. The EventKit adapter lives in the app
/// target; the reconciliation core receives only this portable, read-only shape.
public struct CalendarObservedEvent: Equatable, Sendable, Identifiable {
  public let id: String
  /// Whether `id` is backed by an EventKit identifier rather than the display
  /// fallback used for incomplete subscribed events. A fallback can change when
  /// the event changes, so it may be shown but must never establish a link.
  public var hasStableLocalIdentity: Bool
  /// EventKit does not guarantee this for every subscribed/shared event. It is
  /// useful while observing locally, but never becomes a synced binding.
  public var eventIdentifier: String?
  public var title: String
  public var location: String?
  public var latitude: Double?
  public var longitude: Double?
  public var startDate: Date
  public var endDate: Date
  public var isAllDay: Bool
  public var calendarTitle: String

  public init(
    id: String,
    hasStableLocalIdentity: Bool = true,
    eventIdentifier: String? = nil,
    title: String,
    location: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    startDate: Date,
    endDate: Date,
    isAllDay: Bool,
    calendarTitle: String
  ) {
    self.id = id
    self.hasStableLocalIdentity = hasStableLocalIdentity
    self.eventIdentifier = eventIdentifier
    self.title = title
    self.location = location
    self.latitude = latitude
    self.longitude = longitude
    self.startDate = startDate
    self.endDate = endDate
    self.isAllDay = isAllDay
    self.calendarTitle = calendarTitle
  }
}

/// The Maps identity discovered for a calendar event by `PlaceMatcher`. It is
/// an ephemeral input to matching, not a Calendar binding or persisted fact.
public struct CalendarMatchedPlace: Equatable, Sendable {
  public var name: String
  public var mapItemIdentifier: String?

  public init(name: String, mapItemIdentifier: String? = nil) {
    self.name = name
    self.mapItemIdentifier = mapItemIdentifier
  }
}

/// One EventKit snapshot after the app-side `PlaceMatcher` pass.
public struct CalendarIngestedEvent: Equatable, Sendable, Identifiable {
  public var event: CalendarObservedEvent
  public var matchedPlace: CalendarMatchedPlace?

  public var id: String { event.id }

  public init(event: CalendarObservedEvent, matchedPlace: CalendarMatchedPlace? = nil) {
    self.event = event
    self.matchedPlace = matchedPlace
  }
}

/// An explicitly requested read of an existing local EventKit binding. The
/// binding ID is retained separately because EventKit may return a fresh event
/// identifier after an external edit; it is the stored local binding, not a
/// title or a new match, that establishes the relationship.
public struct CalendarBoundEventObservation: Equatable, Sendable {
  public var bindingID: String
  public var event: CalendarObservedEvent

  public init(bindingID: String, event: CalendarObservedEvent) {
    self.bindingID = bindingID
    self.event = event
  }
}

/// Why the read-only reconciliation view found a candidate. These cases are
/// intentionally descriptive rather than a numeric score: Slice 1 proves a
/// conservative ladder before later slices establish durable links.
public enum CalendarMatchBasis: Equatable, Sendable {
  /// The event and exactly one scheduled pool idea share a Maps place identity.
  case mapItemIdentifier
  /// Exactly one same-day stop has the same normalized visible name.
  case exactName
  /// A same-day event and stop are close together and share a meaningful name token,
  /// but Maps resolved them to different place records. This is review-only evidence.
  case nameAndProximity
}

/// One event's local reconciliation result. Slice 1 never applies this result;
/// it merely makes the ladder inspectable on the device that observed it.
public enum CalendarReconciliationResult: Equatable, Sendable {
  /// Strong enough to link automatically once Slice 2 adds durable authority.
  case automatic(ResolvedStop, basis: CalendarMatchBasis)
  /// Plausible, but requires later human resolution before it could establish a link.
  case proposed(ResolvedStop, basis: CalendarMatchBasis)
  /// More than one same-day stop has the same normalized name.
  case ambiguous([ResolvedStop])
  case unmatched
}

public struct CalendarReconciliationCandidate: Equatable, Sendable, Identifiable {
  public var input: CalendarIngestedEvent
  public var result: CalendarReconciliationResult

  public var id: String { input.id }

  public init(input: CalendarIngestedEvent, result: CalendarReconciliationResult) {
    self.input = input
    self.result = result
  }
}

/// The pure, deliberately conservative first reconciliation ladder. It scopes
/// comparisons to the event's trip day, because a matching restaurant name on a
/// different day is not evidence that the event is the same commitment.
public enum CalendarReconciliation {
  public static func candidates(
    for events: [CalendarIngestedEvent], trip: Trip, plan: TripPlan
  ) -> [CalendarReconciliationCandidate] {
    events.map { event in
      CalendarReconciliationCandidate(input: event, result: result(for: event, trip: trip, plan: plan))
    }
  }

  public static func result(
    for input: CalendarIngestedEvent, trip: Trip, plan: TripPlan
  ) -> CalendarReconciliationResult {
    guard let startDate = trip.startDate else { return .unmatched }
    let dayNumber = Trip.dayNumber(forPinnedDate: input.event.startDate, startDate: startDate)
    guard (1...trip.lengthInDays).contains(dayNumber) else { return .unmatched }
    let stops = plan.itinerary.first(where: { $0.number == dayNumber })?.stops ?? []

    if let mapItemIdentifier = input.matchedPlace?.mapItemIdentifier {
      let matches = stops.filter { $0.idea?.mapItemIdentifier == mapItemIdentifier }
      if matches.count == 1, let match = matches.first {
        return .automatic(match, basis: .mapItemIdentifier)
      }
      if matches.count > 1 { return .ambiguous(matches) }
    }

    let name = normalizedName(input.matchedPlace?.name ?? input.event.title)
    guard !name.isEmpty else { return .unmatched }
    let matches = stops.filter { normalizedName($0.content.title) == name }
    if matches.count == 1, let match = matches.first {
      return .proposed(match, basis: .exactName)
    }
    if matches.count > 1 { return .ambiguous(matches) }

    let nearbyNameMatches = stops.filter { sharesMeaningfulNameToken(input, stop: $0) && isNearby(input, stop: $0) }
    if nearbyNameMatches.count == 1, let match = nearbyNameMatches.first {
      return .proposed(match, basis: .nameAndProximity)
    }
    if nearbyNameMatches.count > 1 { return .ambiguous(nearbyNameMatches) }
    return .unmatched
  }

  /// The pure auto-apply pass for Slice 2. A previously linked event remains
  /// authoritative even if its day or title no longer produces a fresh matching
  /// candidate; its local EventKit identity is the evidence. New links require
  /// the Slice 1 automatic Maps-identity result and exactly one event for the
  /// target stop in this pass. An event that is absent from this read produces no
  /// action — loss of visibility is never inferred as deletion.
  public static func automaticPlan(
    candidates: [CalendarReconciliationCandidate],
    outsideTripObservations: [CalendarBoundEventObservation] = [],
    localState: CalendarReconciliationLocalState,
    observedAt: Date,
    makeHistoryID: () -> UUID,
    calendar: Calendar = .current
  ) -> CalendarReconciliationAutomaticPlan {
    var state = localState
    var applications: [CalendarReconciliationApplication] = []
    let automaticStops = automaticStopCounts(candidates)

    for candidate in candidates {
      let event = candidate.input.event
      guard let commitment = CalendarCommitment(event: event, calendar: calendar) else { continue }

      if let index = state.linkedStops.firstIndex(where: { $0.eventID == event.id }) {
        let linked = state.linkedStops[index]
        guard linked.commitment != commitment || linked.movedOutsideTripCommitment != nil else { continue }
        state.linkedStops[index] = CalendarLinkedStop(
          stopID: linked.stopID,
          eventID: event.id,
          commitment: commitment,
          observedAt: observedAt,
          eventTitle: event.title)
        state.history.append(
          CalendarReconciliationHistoryEntry(
            id: makeHistoryID(),
            kind: .updated,
            stopID: linked.stopID,
            eventID: event.id,
            eventTitle: event.title,
            previous: linked.movedOutsideTripCommitment ?? linked.commitment,
            current: commitment,
            appliedAt: observedAt))
        if linked.commitment != commitment {
          applications.append(
            CalendarReconciliationApplication(stopID: linked.stopID, commitment: commitment, kind: .updated))
        }
        continue
      }

      guard case let .automatic(stop, _) = candidate.result,
        event.hasStableLocalIdentity,
        automaticStops[stop.id] == 1,
        !state.linkedStops.contains(where: { $0.stopID == stop.id })
      else { continue }

      state.linkedStops.append(
        CalendarLinkedStop(
          stopID: stop.id,
          eventID: event.id,
          commitment: commitment,
          observedAt: observedAt,
          eventTitle: event.title))
      state.history.append(
        CalendarReconciliationHistoryEntry(
          id: makeHistoryID(),
          kind: .linked,
          stopID: stop.id,
          eventID: event.id,
          eventTitle: event.title,
          current: commitment,
          appliedAt: observedAt))
      applications.append(
        CalendarReconciliationApplication(stopID: stop.id, commitment: commitment, kind: .linked))
    }

    recordOutsideTripObservations(
      outsideTripObservations, in: &state,
      observedAt: observedAt, makeHistoryID: makeHistoryID,
      calendar: calendar)

    return CalendarReconciliationAutomaticPlan(applications: applications, localState: state)
  }

  private static func automaticStopCounts(
    _ candidates: [CalendarReconciliationCandidate]
  ) -> [TripIdea.ID: Int] {
    candidates.reduce(into: [:]) { counts, candidate in
      guard case let .automatic(stop, _) = candidate.result else { return }
      counts[stop.id, default: 0] += 1
    }
  }

  private static func recordOutsideTripObservations(
    _ observations: [CalendarBoundEventObservation],
    in state: inout CalendarReconciliationLocalState,
    observedAt: Date,
    makeHistoryID: () -> UUID,
    calendar: Calendar
  ) {
    for observation in observations {
      let event = observation.event
      guard
        let commitment = CalendarCommitment(event: event, calendar: calendar),
        let index = state.linkedStops.firstIndex(where: { $0.eventID == observation.bindingID })
      else { continue }

      let linked = state.linkedStops[index]
      guard linked.movedOutsideTripCommitment != commitment else { continue }
      state.linkedStops[index] = CalendarLinkedStop(
        stopID: linked.stopID, eventID: linked.eventID, commitment: linked.commitment,
        observedAt: observedAt, eventTitle: event.title, movedOutsideTripCommitment: commitment)
      state.history.append(
        CalendarReconciliationHistoryEntry(
          id: makeHistoryID(), kind: .movedOutsideTrip, stopID: linked.stopID,
          eventID: linked.eventID, eventTitle: event.title, previous: linked.commitment,
          current: commitment, appliedAt: observedAt))
    }
  }

  /// Comparison-only normalization: case/diacritic/punctuation differences in a
  /// Calendar title must not make one place appear unmatched. Empty names never
  /// match; they carry no place evidence.
  static func normalizedName(_ name: String) -> String {
    name
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .unicodeScalars
      .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
      .joined()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  /// A title fragment is not enough: both sides must share a complete, meaningful
  /// token. This avoids raw-substring accidents such as `bar` matching `barcelona`.
  private static func sharesMeaningfulNameToken(
    _ input: CalendarIngestedEvent, stop: ResolvedStop
  ) -> Bool {
    let eventTokens = Set(normalizedName(input.matchedPlace?.name ?? input.event.title).split(separator: " "))
    let stopTokens = Set(normalizedName(stop.content.title).split(separator: " "))
    return eventTokens.intersection(stopTokens).contains { $0.count >= 4 }
  }

  /// A nearby, differently-resolved Maps record is enough to invite review but is
  /// intentionally not enough to create a Calendar binding. Coordinates must exist
  /// on both sides; absent location facts never turn name similarity into evidence.
  private static func isNearby(_ input: CalendarIngestedEvent, stop: ResolvedStop) -> Bool {
    guard
      let eventLatitude = input.event.latitude,
      let eventLongitude = input.event.longitude,
      let stopLatitude = stop.content.latitude,
      let stopLongitude = stop.content.longitude
    else { return false }

    return distanceInMeters(
      latitude1: eventLatitude,
      longitude1: eventLongitude,
      latitude2: stopLatitude,
      longitude2: stopLongitude) <= 100
  }

  private static func distanceInMeters(
    latitude1: Double,
    longitude1: Double,
    latitude2: Double,
    longitude2: Double
  ) -> Double {
    let latitudeDelta = (latitude2 - latitude1) * .pi / 180
    let longitudeDelta = (longitude2 - longitude1) * .pi / 180
    let haversine = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
      + cos(latitude1 * .pi / 180) * cos(latitude2 * .pi / 180)
      * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
    return 6_371_000 * 2 * atan2(sqrt(haversine), sqrt(1 - haversine))
  }
}

public struct CalendarReconciliationApplication: Equatable, Sendable {
  public var stopID: TripIdea.ID
  public var commitment: CalendarCommitment
  public var kind: CalendarReconciliationHistoryEntry.Kind

  public init(stopID: TripIdea.ID, commitment: CalendarCommitment, kind: CalendarReconciliationHistoryEntry.Kind) {
    self.stopID = stopID
    self.commitment = commitment
    self.kind = kind
  }
}

public struct CalendarReconciliationAutomaticPlan: Equatable, Sendable {
  public var applications: [CalendarReconciliationApplication]
  public var localState: CalendarReconciliationLocalState

  public init(applications: [CalendarReconciliationApplication], localState: CalendarReconciliationLocalState) {
    self.applications = applications
    self.localState = localState
  }
}
