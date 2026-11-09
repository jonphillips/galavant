import GalavantSchema

extension TripPlanningModel {
  /// Present a pulled idea's read-only detail from the visible planning surface.
  func showDetail(_ idea: Idea, stopID: TripIdea.ID? = nil) {
    detailIdeaID = idea.id
    detailStopID = stopID
    routeIdeaDetailDay = nil
    routeIdeaDetailAction = nil
  }

  /// Resolve the presented detail's idea by ID, or nil if it was deleted while open
  /// (ADR-0007 read-time reconciliation).
  func ideaForDetail(_ id: Idea.ID) -> Idea? { ideas.first { $0.id == id } }

  func rationaleForDetail() -> TripRationale? {
    guard let detailStopID else { return nil }
    return entries.first { $0.id == detailStopID }?.rationale
  }

  /// The stop's itinerary placement, when the idea is a scheduled stop on the trip.
  /// A plain pool idea has no stop row, so its detail remains placement-free.
  func stopContext(for idea: Idea) -> StopDetailContext? {
    guard let entry = entries.first(where: { $0.ideaID == idea.id && $0.status == .scheduled })
    else { return nil }
    let schedule = entry.schedule
    let label = schedule.dayNumber.map { dayLabel($0, trip: trip) } ?? "To Be Scheduled"
    return StopDetailContext(
      dayLabel: label, schedule: schedule, calendarNotes: entry.calendarNotes)
  }
}
