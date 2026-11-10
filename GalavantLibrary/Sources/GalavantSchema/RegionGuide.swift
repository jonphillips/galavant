import Foundation

public enum GuideCategory: String, CaseIterable, Equatable, Sendable {
  case dining
  case hotels

  public var kindGroup: IdeaKindGroup {
    switch self {
    case .dining: .food
    case .hotels: .stay
    }
  }
}

public enum GuideShelf: String, CaseIterable, Equatable, Sendable {
  case all
  case wantToGo
  case noted
  case notForMe

  public var label: String {
    switch self {
    case .all: "All"
    case .wantToGo: "Want to Go"
    case .noted: "Noted"
    case .notForMe: "Not for Me"
    }
  }
}

public struct RegionGuideScope: Equatable, Hashable, Identifiable, Sendable {
  public var region: MapRegion?
  public var category: GuideCategory
  public var preferredTripID: Trip.ID?
  public var id: String { "\(region?.id.uuidString ?? "none")-\(category.rawValue)-\(preferredTripID?.uuidString ?? "none")" }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(region?.id)
    hasher.combine(category)
    hasher.combine(preferredTripID)
  }

  public init(region: MapRegion?, category: GuideCategory, preferredTripID: Trip.ID? = nil) {
    self.region = region
    self.category = category
    self.preferredTripID = preferredTripID
  }

  public init(
    selectedRegion: MapRegion?,
    activeTripRegions: [MapRegion],
    lastGuideRegion: MapRegion?,
    selectedKindGroups: Set<IdeaKindGroup>,
    preferredTripID: Trip.ID? = nil
  ) {
    self.init(
      region: selectedRegion ?? (activeTripRegions.count == 1 ? activeTripRegions.first : nil) ?? lastGuideRegion,
      category: selectedKindGroups == [.stay] ? .hotels : .dining,
      preferredTripID: preferredTripID
    )
  }
}

public struct RegionGuide: Equatable, Sendable {
  public struct Card: Identifiable, Equatable, Sendable {
    public var idea: Idea
    public var accolade: IdeaEvaluation?
    public var interests: [PlannerInterest]
    public var standing: MatchStanding
    public var latestNote: TasteNote?
    public var noteCount: Int
    public var emphasis: Emphasis
    public var id: Idea.ID { idea.id }
  }

  public struct Section: Identifiable, Equatable, Sendable {
    public var title: String
    public var cards: [Card]
    public var id: String

    public init(title: String, cards: [Card], id: String) {
      self.title = title
      self.cards = cards
      self.id = id
    }
  }

  public var sections: [Section]
  public var counts: [GuideShelf: Int]

  public init(sections: [Section], counts: [GuideShelf: Int]) {
    self.sections = sections
    self.counts = counts
  }

  public init(
    region: MapRegion,
    category: GuideCategory,
    shelf: GuideShelf,
    ideas: [Idea],
    evaluations: [IdeaEvaluation],
    interests: [IdeaInterest],
    planners: [Planner],
    notes: [TasteNote]
  ) {
    let members = poolFiltered(ideas, regions: [region], kindGroups: [category.kindGroup])
    let cards = Self.makeCards(
      members: members, evaluations: evaluations, interests: interests, planners: planners, notes: notes)
    counts = Self.shelfCounts(cards)
    sections = Self.sections(cards, shelf: shelf)
  }

  private enum AccoladeKey: Hashable {
    case other
    case accolade(source: String, display: String)
  }
}

private extension RegionGuide {
  static func makeCards(
    members: [Idea], evaluations: [IdeaEvaluation], interests: [IdeaInterest],
    planners: [Planner], notes: [TasteNote]
  ) -> [Card] {
    let knownIDs = Set(members.map(\.id))
    let currentEvaluations = Dictionary(grouping: evaluations.filter { $0.staleness == .current }, by: \.ideaID)
    let interestsByIdea = Dictionary(
      grouping: interests.convergingByKey { [$0.ideaID, $0.plannerID] }.survivors, by: \.ideaID)
    let notesByIdea = notes.filter { $0.ideaID != nil }.reduce(into: [Idea.ID: [TasteNote]]()) { result, note in
      guard let ideaID = note.ideaID else { return }
      result[ideaID, default: []].append(note)
    }.mapValues {
      TasteNote.newestFirst($0)
    }
    return members.map { idea in
      let plannerInterests = PlannerInterest.list(
        planners: planners, levels: interestsByIdea[idea.id] ?? [])
      let ideaNotes = notesByIdea[idea.id] ?? []
      return Card(
        idea: idea,
        accolade: IdeaEvaluation.headline(
          forIdea: idea.id, from: currentEvaluations[idea.id] ?? [], knownIdeaIDs: knownIDs),
        interests: plannerInterests,
        standing: Interest.standing(plannerInterests.map(\.level)),
        latestNote: ideaNotes.first,
        noteCount: ideaNotes.count,
        emphasis: Emphasis.forKind(idea.kind)
      )
    }
  }

  static func shelfCounts(_ cards: [Card]) -> [GuideShelf: Int] {
    Dictionary(uniqueKeysWithValues: GuideShelf.allCases.map { shelf in
      (shelf, cards.filter { belongs($0, to: shelf) }.count)
    })
  }

  static func belongs(_ card: Card, to shelf: GuideShelf) -> Bool {
    let notForMe = card.interests.contains { $0.level == .doNotDo }
      && !card.interests.contains { $0.level == .wantToDo || $0.level == .mustDo }
    return switch shelf {
    case .all: !notForMe
    case .wantToGo: card.interests.contains { $0.level == .wantToDo || $0.level == .mustDo }
    case .noted: card.noteCount > 0 && !notForMe
    case .notForMe: notForMe
    }
  }

  static func sections(_ cards: [Card], shelf: GuideShelf) -> [Section] {
    let visibleCards = cards.filter { belongs($0, to: shelf) }
    let grouped = Dictionary(grouping: visibleCards) { card -> AccoladeKey in
      guard let accolade = card.accolade else { return .other }
      return .accolade(source: accolade.canonicalSourceName, display: accolade.nativeDisplay)
    }
    let evaluations = Dictionary(grouping: visibleCards.compactMap(\.accolade)) {
      AccoladeKey.accolade(source: $0.canonicalSourceName, display: $0.nativeDisplay)
    }.compactMapValues(\.first)
    return grouped.keys.sorted { keysPrecede($0, $1, evaluations: evaluations) }.map { key in
      let sectionCards = (grouped[key] ?? []).sorted {
        if $0.standing != $1.standing { return $0.standing.sortKey < $1.standing.sortKey }
        return $0.idea.name.localizedCaseInsensitiveCompare($1.idea.name) == .orderedAscending
      }
      return switch key {
      case .other:
        Section(title: "Other places", cards: sectionCards, id: "other")
      case let .accolade(source, display):
        Section(title: "\(source) · \(display)", cards: sectionCards, id: "\(source)\u{1f}\(display)")
      }
    }
  }

  private static func keysPrecede(
    _ lhs: AccoladeKey, _ rhs: AccoladeKey, evaluations: [AccoladeKey: IdeaEvaluation]
  ) -> Bool {
    switch (lhs, rhs) {
    case (.other, .other), (.other, .accolade): return false
    case (.accolade, .other): return true
    case let (.accolade(sourceA, displayA), .accolade(sourceB, displayB)):
      let evaluationA = evaluations[lhs]
      let evaluationB = evaluations[rhs]
      let rankA = evaluationA.map(IdeaEvaluation.headlineRank) ?? Int.max
      let rankB = evaluationB.map(IdeaEvaluation.headlineRank) ?? Int.max
      if rankA != rankB { return rankA < rankB }
      let numberA = evaluationA?.nativeValueNumber ?? -.infinity
      let numberB = evaluationB?.nativeValueNumber ?? -.infinity
      if numberA != numberB { return numberA > numberB }
      return "\(sourceA) · \(displayA)".localizedCaseInsensitiveCompare("\(sourceB) · \(displayB)") == .orderedAscending
    }
  }
}
