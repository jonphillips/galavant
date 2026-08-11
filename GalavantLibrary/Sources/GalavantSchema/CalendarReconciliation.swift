import Foundation

/// A value snapshot of an EventKit event. The EventKit adapter lives in the app
/// target; the reconciliation core receives only this portable, read-only shape.
public struct CalendarObservedEvent: Equatable, Sendable, Identifiable {
  public let id: String
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

/// Why the read-only reconciliation view found a candidate. These cases are
/// intentionally descriptive rather than a numeric score: Slice 1 proves a
/// conservative ladder before later slices establish durable links.
public enum CalendarMatchBasis: Equatable, Sendable {
  /// The event and exactly one scheduled pool idea share a Maps place identity.
  case mapItemIdentifier
  /// Exactly one same-day stop has the same normalized visible name.
  case exactName
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
    return .unmatched
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
}
