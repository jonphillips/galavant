import Foundation

/// The guide's focused meal cell, projected into cards or itinerary rows.
public struct GuideSlotFocus: Equatable, Sendable {
  public struct Stop: Identifiable, Equatable, Sendable {
    public var id: TripIdea.ID
    public var ideaID: Idea.ID?
    public var title: String
    public var isFreeform: Bool
    public var isActive: Bool
    public var alternativeGroupID: UUID?

    public var isAlternative: Bool { alternativeGroupID != nil }
  }

  public enum Content: Equatable, Sendable {
    case open(ideaIDs: [Idea.ID])
    case filled([Stop])
  }

  public var day: Int
  public var meal: Meal
  public var weekday: Weekday?
  public var content: Content

  public var title: String {
    let dayLabel = weekday?.shortLabel ?? "Day \(day)"
    return switch content {
    case .open: "\(dayLabel) \(meal.label.lowercased()) is open"
    case .filled: "Showing options for \(dayLabel) \(meal.label.lowercased())"
    }
  }

  public var ideaIDs: [Idea.ID] {
    switch content {
    case let .open(ideaIDs): ideaIDs
    case let .filled(stops): stops.compactMap(\.ideaID)
    }
  }

  public var isFilled: Bool {
    if case .filled = content { return true }
    return false
  }

  public init?(
    day: Int, meal: Meal, lens: GuideTripLens, entries: [TripIdea], ideas: [Idea],
    candidateIdeaIDs: Set<Idea.ID>? = nil
  ) {
    guard case let .meals(days) = lens.body,
      let mealDay = days.first(where: { $0.day == day })
    else { return nil }
    self.day = day
    self.meal = meal
    weekday = mealDay.weekday
    let cell = meal == .lunch ? mealDay.lunch : mealDay.dinner
    switch cell {
    case .open:
      let candidateIDs = ideas.filter { idea in
        if let candidateIdeaIDs, !candidateIdeaIDs.contains(idea.id) { return false }
        guard let weekday = mealDay.weekday else { return true }
        return idea.weeklyHours?.serves(meal, on: weekday) != false
      }.map(\.id)
      content = .open(ideaIDs: candidateIDs)
    case let .filled(slotStops):
      let entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let ideasByID = Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let entriesByGroup = Dictionary(grouping: entries.compactMap { entry -> (UUID, TripIdea)? in
        entry.alternativeGroupID.map { ($0, entry) }
      }, by: \.0).mapValues { $0.map(\.1) }
      var stops: [Stop] = []
      for slotStop in slotStops {
        guard let entry = entriesByID[slotStop.id] else { continue }
        let members: [TripIdea]
        if let groupID = entry.alternativeGroupID {
          members = TripIdea.canonicalAlternativeOrder(entriesByGroup[groupID] ?? [entry])
        } else {
          members = [entry]
        }
        for member in members {
          let title = member.ideaID.flatMap { ideasByID[$0]?.name } ?? member.inlineTitle ?? slotStop.title
          stops.append(Stop(
            id: member.id, ideaID: member.ideaID, title: title, isFreeform: member.ideaID == nil,
            isActive: member.id == slotStop.id, alternativeGroupID: member.alternativeGroupID))
        }
      }
      content = .filled(stops)
    }
  }
}
