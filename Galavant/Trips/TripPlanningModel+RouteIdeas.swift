import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

extension TripPlanningModel {
  /// Corridor candidates are filtered for the active day; geometry is cached by
  /// the route and candidate values so map annotations do not rebuild distances.
  func ideasAlongRoute(forDay day: Int) -> [RouteCorridor.Match] {
    let candidates = RouteIdeaCandidates.filter(ideas: ideas, tripIdeas: entries, day: day)
    return routeIdeasSnapshot.matches(
      route: plan.routeEndpoints(forDay: day), candidates: candidates)
  }

  func idea(id: Idea.ID) -> Idea? { ideas.first { $0.id == id } }

  /// Add a corridor idea, or move its scheduled stop, in a single database write.
  func addAlongRoute(_ idea: Idea, toDay day: Int) {
    let (tripID, ideaID) = (tripID, idea.id)
    let didSave = withErrorReporting {
      try database.write { db in
        try TripIdea.pull(ideaID: ideaID, into: tripID, in: db)
        try TripIdea.setStatus(.shortlisted, ideaID: ideaID, tripID: tripID, in: db)
        try TripIdea.schedule(.day(day), ideaID: ideaID, tripID: tripID, in: db)
      }
      return true
    } ?? false
    if didSave { routeIdeaAddFeedback += 1 }
  }

  /// Present a pulled idea's read-only detail from the visible planning surface.
  func showDetail(_ idea: Idea, stopID: TripIdea.ID? = nil) {
    detailIdeaID = idea.id
    detailStopID = stopID
    routeIdeaDetailDay = nil
  }

  func showRouteIdeaDetail(_ idea: Idea, day: Int) {
    showDetail(idea)
    routeIdeaDetailDay = day
  }

  func routeIdeaActionTitle(for idea: Idea) -> String? {
    guard let day = routeIdeaDetailDay,
      !entries.contains(where: { $0.ideaID == idea.id && $0.alternativeGroupID != nil })
    else { return nil }
    let label = dayLabel(day, trip: trip)
    let scheduled = entries.first { $0.ideaID == idea.id && $0.status == .scheduled }
    return scheduled.map { $0.dayNumber == day ? nil : "Move to \(label)" } ?? "Add to \(label)"
  }

  func addRouteIdeaDetailToDay(_ idea: Idea) {
    guard let day = routeIdeaDetailDay else { return }
    addAlongRoute(idea, toDay: day)
  }

  /// Resolve the presented detail's idea, or nil if it was deleted while open.
  func ideaForDetail(_ id: Idea.ID) -> Idea? { idea(id: id) }

  func rationaleForDetail() -> TripRationale? {
    guard let detailStopID else { return nil }
    return entries.first { $0.id == detailStopID }?.rationale
  }

  /// This idea's itinerary placement, if it is a scheduled stop on this trip.
  func stopContext(for idea: Idea) -> StopDetailContext? {
    guard let entry = entries.first(where: { $0.ideaID == idea.id && $0.status == .scheduled })
    else { return nil }
    let schedule = entry.schedule
    let label = schedule.dayNumber.map { dayLabel($0, trip: trip) } ?? "To Be Scheduled"
    return StopDetailContext(
      dayLabel: label, schedule: schedule, calendarNotes: entry.calendarNotes)
  }
}
