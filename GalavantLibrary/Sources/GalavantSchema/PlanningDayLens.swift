import Foundation

/// The planning surface's *sense of now*: the day lens a trip opens on.
///
/// A trip that is underway opens on its live day rather than the whole-trip "All"
/// lens — when the trip is on, the surface should already be where you are. A trip
/// that is undated, finished, or still ahead keeps the whole-trip lens.
///
/// The rule is deliberately a **one-shot**: the seed is offered once per planning
/// session and never again, so a later clock tick can't yank the lens out from
/// under a user who has explicitly chosen a different day (or "All"). Holding that
/// once-ness in a value — rather than a boolean inside the feature model — is what
/// makes it testable; the model just owns an instance of it.
public struct DayLensSeeding: Equatable, Sendable {
  /// True once the seeding opportunity has been taken, whether or not it yielded a
  /// day. Exposed so a caller can reason about the rule, not to re-open it.
  public private(set) var hasSeeded = false

  public init() {}

  /// The day the lens should open on, or `nil` to leave the lens where it is.
  ///
  /// Consumes the single seeding opportunity on the first call, even when the trip
  /// isn't underway — "we already decided not to move the lens" is as final as
  /// "we moved it".
  public mutating func seedDay(
    now: Date, tripStartDate: Date?, lengthInDays: Int
  ) -> Int? {
    guard !hasSeeded else { return nil }
    hasSeeded = true
    guard let tripStartDate else { return nil }
    return TodayProjection.tripDay(
      containing: now, tripStartDate: tripStartDate, lengthInDays: lengthInDays)
  }
}
