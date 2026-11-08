import Foundation

public struct IdeaDossier: Equatable, Sendable {
  public var idea: Idea
  public var accolades: Accolades
  public var interests: [PlannerInterest]
  public var standing: MatchStanding
  public var notes: [TasteNote]
  public var tagNames: [String]
  public var photos: [DossierPhoto]
  public var emphasis: Emphasis

  public init(
    idea: Idea,
    evaluations: [IdeaEvaluation],
    interests: [IdeaInterest],
    planners: [Planner],
    notes: [TasteNote],
    tags: [Tag],
    ideaTags: [IdeaTag],
    photos: [(id: ImageAsset.ID, ideaID: Idea.ID, thumbnail: Data, sortRank: Int, isHeader: Bool)],
    knownIdeaIDs: Set<Idea.ID>
  ) {
    self.idea = idea
    let split = IdeaEvaluation.currentAndHistorical(
      forIdea: idea.id, from: evaluations, knownIdeaIDs: knownIdeaIDs)
    self.accolades = Accolades(current: split.current, historical: split.historical)

    let converged = interests.convergingByKey { [$0.ideaID, $0.plannerID] }.survivors
    let byPlanner = Dictionary(
      uniqueKeysWithValues: converged.filter { $0.ideaID == idea.id }.map { ($0.plannerID, $0.level) })
    self.interests = planners
      .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
      .map { PlannerInterest(planner: $0, level: byPlanner[$0.id] ?? nil) }
    self.standing = Interest.standing(self.interests.map(\.level))
    self.notes = notes
      .filter { $0.ideaID == idea.id }
      .sorted { $0.notedAt == $1.notedAt ? $0.id.uuidString < $1.id.uuidString : $0.notedAt > $1.notedAt }
    self.tagNames = TagIndex(tags: tags, ideaTags: ideaTags).names(for: idea.id)
    self.photos = photos
      .filter { $0.ideaID == idea.id && !$0.isHeader }
      .sorted { $0.sortRank == $1.sortRank ? $0.id.uuidString < $1.id.uuidString : $0.sortRank < $1.sortRank }
      .map { DossierPhoto(id: $0.id, thumbnail: $0.thumbnail) }
    self.emphasis = IdeaKindGroup(kind: idea.kind) == .stay ? .notesFirst : .accoladesFirst
  }
}

public struct PlannerInterest: Equatable, Sendable {
  public var planner: Planner
  public var level: Interest?
}

public struct Accolades: Equatable, Sendable {
  public var current: [IdeaEvaluation]
  public var historical: [IdeaEvaluation]
}

public struct DossierPhoto: Identifiable, Equatable, Sendable {
  public var id: ImageAsset.ID
  public var thumbnail: Data
}

public enum Emphasis: Equatable, Sendable {
  case accoladesFirst
  case notesFirst
}
