import Foundation

public struct IdeaDossier: Equatable, Sendable {
  public var idea: Idea
  public var accolades: Accolades
  public var interests: [PlannerInterest]
  public var standing: MatchStanding
  public var notes: [TasteNote]
  public var tagNames: [String]
  public var photos: [DossierPhoto]
  public var notesPlacement: NotesPlacement

  public init(
    idea: Idea,
    evaluations: [IdeaEvaluation],
    interests: [IdeaInterest],
    planners: [Planner],
    notes: [TasteNote],
    tags: [Tag],
    ideaTags: [IdeaTag],
    photos: [(id: ImageAsset.ID, ideaID: Idea.ID, thumbnail: Data, sortRank: Int, isHeader: Bool)],
    knownIdeaIDs: Set<Idea.ID>,
    stops: [TripIdea] = [],
    trips: [Trip] = [],
    now: Date? = nil,
    calendar: Calendar = .current
  ) {
    self.idea = idea
    let split = IdeaEvaluation.currentAndHistorical(
      forIdea: idea.id, from: evaluations, knownIdeaIDs: knownIdeaIDs)
    self.accolades = Accolades(current: split.current, historical: split.historical)

    self.interests = PlannerInterest.list(
      planners: planners, levels: interests.filter { $0.ideaID == idea.id })
    self.standing = Interest.standing(self.interests.map(\.level))
    self.notes = TasteNote.newestFirst(notes.filter { $0.ideaID == idea.id })
    self.tagNames = TagIndex(tags: tags, ideaTags: ideaTags).names(for: idea.id)
    self.photos = photos
      .filter { $0.ideaID == idea.id && !$0.isHeader }
      .sorted { $0.sortRank == $1.sortRank ? $0.id.uuidString < $1.id.uuidString : $0.sortRank < $1.sortRank }
      .map { DossierPhoto(id: $0.id, thumbnail: $0.thumbnail) }
    self.notesPlacement = NotesPlacement.forIdea(idea, stops: stops, trips: trips, now: now, calendar: calendar)
  }
}

public struct PlannerInterest: Equatable, Sendable {
  public var planner: Planner
  public var level: Interest?

  public static func list(planners: [Planner], levels: [IdeaInterest]) -> [PlannerInterest] {
    let converged = levels.convergingByKey { [$0.plannerID] }.survivors
    let byPlanner = Dictionary(uniqueKeysWithValues: converged.map { ($0.plannerID, $0.level) })
    return planners
      .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
      .map { PlannerInterest(planner: $0, level: byPlanner[$0.id] ?? nil) }
  }
}

public struct Accolades: Equatable, Sendable {
  public var current: [IdeaEvaluation]
  public var historical: [IdeaEvaluation]
}

public struct DossierPhoto: Identifiable, Equatable, Sendable {
  public var id: ImageAsset.ID
  public var thumbnail: Data
}

public enum NotesPlacement: Equatable, Sendable {
  case top
  case bottom

  public static func forIdea(
    _ idea: Idea, stops: [TripIdea], trips: [Trip], now: Date?, calendar: Calendar
  ) -> NotesPlacement {
    guard !idea.visited else { return .top }
    let ideaStops = stops.filter { $0.ideaID == idea.id }
    guard !ideaStops.isEmpty else { return .bottom }
    if ideaStops.contains(where: { $0.completedAt != nil }) { return .top }
    guard let now else { return .bottom }
    let tripsByID = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let today = calendar.startOfDay(for: now)
    let hasPastScheduledStop = ideaStops.contains { stop in
      guard stop.status == .scheduled, stop.skippedAt == nil,
        let dayNumber = stop.dayNumber,
        let startDate = tripsByID[stop.tripID]?.startDate,
        let dayDate = calendar.date(byAdding: .day, value: dayNumber - 1, to: startDate)
      else { return false }
      return calendar.startOfDay(for: dayDate) < today
    }
    return hasPastScheduledStop ? .top : .bottom
  }
}

/// Compact guide cards keep their kind-based ordering; the full dossier uses
/// `NotesPlacement`, which accounts for visits and trip history.
public enum Emphasis: Equatable, Sendable {
  case accoladesFirst
  case notesFirst

  public static func forKind(_ kind: IdeaKind?) -> Emphasis {
    IdeaKindGroup(kind: kind) == .stay ? .notesFirst : .accoladesFirst
  }
}
