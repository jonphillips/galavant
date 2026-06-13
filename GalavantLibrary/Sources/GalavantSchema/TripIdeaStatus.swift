import SQLiteData

/// Where an idea sits in a trip's pull-based lifecycle (ADR-0004). Ideas are
/// never *contained* by a trip; this status on the `TripIdea` join carries the
/// relationship. Raw values order the live pipeline; `done`/`skipped` are the
/// post-trip terminals that feed visited-state back to the pool. Never renumber.
public enum TripIdeaStatus: Int, QueryBindable, CaseIterable, Sendable {
  case considering = 0
  case shortlisted = 1
  case scheduled = 2
  case done = 3
  case skipped = 4

  public var label: String {
    switch self {
    case .considering: "Considering"
    case .shortlisted: "Shortlisted"
    case .scheduled: "Scheduled"
    case .done: "Done"
    case .skipped: "Skipped"
    }
  }

  /// True once the idea has earned a place on the trip (shortlisted onward),
  /// as opposed to merely being weighed.
  public var isOnShortlist: Bool {
    switch self {
    case .considering, .skipped: false
    case .shortlisted, .scheduled, .done: true
    }
  }
}
