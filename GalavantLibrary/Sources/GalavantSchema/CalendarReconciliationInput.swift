import Foundation

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
  /// Explicit itinerary/day zone resolved from the matched location. Nil is an
  /// unresolved reconciliation fact for absolute events, never a device fallback.
  public var itineraryTimeZone: TimeZone?

  public var id: String { event.id }

  public init(
    event: CalendarObservedEvent,
    matchedPlace: CalendarMatchedPlace? = nil,
    itineraryTimeZone: TimeZone? = nil
  ) {
    self.event = event
    self.matchedPlace = matchedPlace
    self.itineraryTimeZone = itineraryTimeZone
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
