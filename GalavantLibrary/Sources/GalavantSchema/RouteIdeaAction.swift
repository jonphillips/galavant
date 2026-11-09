import SQLiteData

/// The resolved action a route idea detail will perform. Move carries the exact
/// itinerary stop shown by the detail, so repeated occurrences stay unambiguous.
public enum RouteIdeaAction: Equatable, Sendable {
  case add(ideaID: Idea.ID)
  case move(ideaID: Idea.ID, stopID: TripIdea.ID)
}

extension TripIdea {
  /// Pull and schedule a pool idea, or move the specific scheduled occurrence
  /// resolved when its detail opened. The caller wraps this composition in one write.
  public static func applyRouteIdeaAction(
    _ action: RouteIdeaAction,
    into tripID: Trip.ID,
    on day: Int,
    in db: Database
  ) throws {
    switch action {
    case let .add(ideaID):
      try pull(ideaID: ideaID, into: tripID, in: db)
      try setStatus(.shortlisted, ideaID: ideaID, tripID: tripID, in: db)
      try schedule(.day(day), ideaID: ideaID, tripID: tripID, in: db)
    case let .move(ideaID, stopID):
      guard let stop = try TripIdea.find(stopID).fetchOne(db),
        stop.tripID == tripID,
        stop.ideaID == ideaID,
        stop.status == .scheduled,
        stop.dayNumber != nil
      else { throw TripError.invalidRouteIdeaAction }
      try schedule(.day(day), stopID: stopID, in: db)
    }
  }
}
