import Foundation

/// An idea's trip association, projected from its `TripIdea` join rows for the
/// Ideas-screen cell badge (ADR-0007: there is no `idea.tripID`; association is
/// always a query over joins). An idea can ride several trips at once, so the
/// badge shows the **most-actionable** status — `scheduled > upcoming > someday
/// > visited` — and a *free* idea (on no trip, never visited) gets no badge at
/// all, keeping the junk drawer quiet. Pure, so it's the densely-tested core
/// (sits beside `poolFiltered`).
public enum IdeaTripBadge: Equatable, Sendable {
  /// On a trip's itinerary. `dayNumber` is nil for the "To Be Scheduled" bucket.
  case scheduled(trip: String, dayNumber: Int?)
  /// Pulled onto a dated/targeted (in-play) trip, not yet scheduled.
  case upcoming(trip: String)
  /// Pulled onto a someday trip.
  case someday(trip: String)
  /// Visited, with no live trip association to show instead.
  case visited

  /// Ranks the cases so the most-actionable association wins when an idea is on
  /// several trips. Higher = more actionable.
  var tier: Int {
    switch self {
    case .scheduled: 4
    case .upcoming: 3
    case .someday: 2
    case .visited: 1
    }
  }
}

extension IdeaTripBadge {
  /// The badge for `idea`, given its own `TripIdea` rows (any trip) and a lookup
  /// of the trips they point at. Returns nil for a free idea.
  ///
  /// Live associations (a real `TripIdea`) outrank a bare `visited` flag. Among
  /// candidates of the same tier the one on the soonest trip wins (dated by
  /// date, then name) so the result is deterministic. `.done`/`.skipped` joins
  /// are ignored — a done stop has already flipped `idea.visited`, and a skipped
  /// one is a negative signal, not an association to advertise.
  public static func badge(
    forIdea idea: Idea,
    entries: [TripIdea],
    tripsByID: [Trip.ID: Trip]
  ) -> IdeaTripBadge? {
    let candidates: [(badge: IdeaTripBadge, trip: Trip)] = entries.compactMap { entry in
      guard let trip = tripsByID[entry.tripID] else { return nil }
      switch entry.status {
      case .scheduled:
        return (.scheduled(trip: trip.name, dayNumber: entry.dayNumber), trip)
      case .considering, .shortlisted:
        switch trip.certaintyStage {
        case .dated, .targeted: return (.upcoming(trip: trip.name), trip)
        case .someday: return (.someday(trip: trip.name), trip)
        }
      case .done, .skipped:
        return nil
      }
    }

    let best = candidates.max { lhs, rhs in
      if lhs.badge.tier != rhs.badge.tier { return lhs.badge.tier < rhs.badge.tier }
      return tripPrecedes(rhs.trip, lhs.trip)  // earlier trip should sort last (= max)
    }
    if let best { return best.badge }
    return idea.visited ? .visited : nil
  }

  /// Soonest-trip ordering used to break ties: dated trips first (by start
  /// date), then any other, then name. Total and deterministic.
  private static func tripPrecedes(_ lhs: Trip, _ rhs: Trip) -> Bool {
    let l = (lhs.startDate ?? .distantFuture, lhs.name.lowercased())
    let r = (rhs.startDate ?? .distantFuture, rhs.name.lowercased())
    return l < r
  }
}
