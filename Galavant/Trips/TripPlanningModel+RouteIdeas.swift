import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

extension TripPlanningModel {
  /// Corridor candidates are filtered for the active day; geometry is cached by
  /// the route and candidate values so map annotations do not rebuild distances.
  func ideasAlongRoute(forDay day: Int) -> [RouteIdeaPinModel] {
    let candidates = RouteIdeaCandidates.filter(ideas: ideas, tripIdeas: entries, day: day)
    return routeIdeasSnapshot.matches(
      route: plan.routeEndpoints(forDay: day), candidates: candidates)
  }

  /// Add a corridor idea, or move its scheduled stop, in a single database write.
  private func applyRouteIdeaAction(_ action: RouteIdeaAction, on day: Int) {
    let tripID = tripID
    let didSave = withErrorReporting {
      try database.write { db in
        try TripIdea.applyRouteIdeaAction(action, into: tripID, on: day, in: db)
      }
      return true
    } ?? false
    guard didSave else { return }
    // The action is spent: clearing it hides the button while the detail stays open.
    routeIdeaDetailAction = nil
    routeIdeaAddFeedback += 1
  }

  func showRouteIdeaDetail(_ idea: Idea, day: Int) {
    showDetail(idea)
    routeIdeaDetailDay = day
    guard !entries.contains(where: { $0.ideaID == idea.id && $0.alternativeGroupID != nil }) else {
      return
    }
    let scheduledOccurrences = entries
      .filter {
        $0.ideaID == idea.id && $0.status == .scheduled
          && $0.dayNumber != nil && $0.dayNumber != day
      }
      .sorted { lhs, rhs in
        let leftDay = lhs.dayNumber ?? 0
        let rightDay = rhs.dayNumber ?? 0
        if leftDay != rightDay { return leftDay < rightDay }
        return lhs.id.uuidString < rhs.id.uuidString
      }
    if let stop = scheduledOccurrences.first {
      routeIdeaDetailAction = .move(ideaID: idea.id, stopID: stop.id)
    } else {
      routeIdeaDetailAction = .add(ideaID: idea.id)
    }
  }

  func routeIdeaActionTitle(for idea: Idea) -> String? {
    guard let day = routeIdeaDetailDay, let action = routeIdeaDetailAction else { return nil }
    let label = dayLabel(day, trip: trip)
    switch action {
    case let .add(ideaID): return ideaID == idea.id ? "Add to \(label)" : nil
    case let .move(ideaID, _): return ideaID == idea.id ? "Move to \(label)" : nil
    }
  }

  func addRouteIdeaDetailToDay(_ idea: Idea) {
    guard let day = routeIdeaDetailDay, let action = routeIdeaDetailAction else { return }
    switch action {
    case let .add(ideaID), let .move(ideaID, _):
      guard ideaID == idea.id else { return }
    }
    applyRouteIdeaAction(action, on: day)
  }

}
