import Foundation
import GalavantSchema
import Testing

@Suite struct RegionGuideTests {
  let region = MapRegion(
    id: UUID(), name: "Virginia", centerLatitude: 38, centerLongitude: -78,
    latitudeDelta: 8, longitudeDelta: 8
  )
  let partyID = UUID()
  let planners = [
    Planner(id: UUID(), displayName: "Jon"),
    Planner(id: UUID(), displayName: "Wendy"),
  ]

  func idea(_ name: String, kind: IdeaKind = .food, latitude: Double? = 38, longitude: Double? = -78) -> Idea {
    Idea(id: UUID(), name: name, kind: kind, latitude: latitude, longitude: longitude)
  }

  func evaluation(
    for idea: Idea,
    source: String = "Michelin Guide",
    display: String = "★★",
    number: Double? = 2,
    kind: EvaluationKind = .stars,
    staleness: EvaluationStaleness = .current
  ) -> IdeaEvaluation {
    IdeaEvaluation(
      id: UUID(), travelPartyID: partyID, ideaID: idea.id, sourceName: source, kind: kind,
      nativeValueText: display, nativeValueNumber: number, nativeDisplay: display,
      recordedAt: Date(timeIntervalSince1970: 1), confidence: .official, staleness: staleness
    )
  }

  func interest(_ idea: Idea, _ planner: Planner, _ level: Interest?) -> IdeaInterest {
    IdeaInterest(id: UUID(), ideaID: idea.id, plannerID: planner.id, level: level)
  }

  func guide(
    _ ideas: [Idea],
    evaluations: [IdeaEvaluation] = [],
    interests: [IdeaInterest] = [],
    notes: [TasteNote] = [],
    category: GuideCategory = .dining,
    shelf: GuideShelf = .all
  ) -> RegionGuide {
    RegionGuide(
      region: region, category: category, shelf: shelf, ideas: ideas, evaluations: evaluations,
      interests: interests, planners: planners, notes: notes
    )
  }

  @Test func shelvesCoverEveryPairOfPlannerLevelsAndCounts() {
    let levels: [Interest?] = [nil, .doNotDo, .couldDo, .wantToDo, .mustDo]
    for first in levels {
      for second in levels {
        let place = idea("Place")
        let built = guide([place], interests: [interest(place, planners[0], first), interest(place, planners[1], second)])
        let notForMe = [first, second].contains(.doNotDo)
          && ![first, second].contains(where: { $0 == .wantToDo || $0 == .mustDo })
        let wantToGo = [first, second].contains(where: { $0 == .wantToDo || $0 == .mustDo })
        #expect(built.counts[.all] == (notForMe ? 0 : 1))
        #expect(built.counts[.wantToGo] == (wantToGo ? 1 : 0))
        #expect(built.counts[.noted] == 0)
        #expect(built.counts[.notForMe] == (notForMe ? 1 : 0))
      }
    }
  }

  @Test func membershipRequiresLocationRegionAndCategory() {
    let noLocation = idea("Unlocated", latitude: nil, longitude: nil)
    let outside = idea("Outside", latitude: 60, longitude: -78)
    let hotel = idea("Hotel", kind: .stay)
    let inside = idea("Inside")
    #expect(guide([noLocation, outside, hotel, inside]).sections.flatMap(\.cards).map(\.idea.id) == [inside.id])
    #expect(guide([hotel], category: .dining).sections.isEmpty)
    #expect(guide([hotel], category: .hotels).sections.flatMap(\.cards).map(\.idea.id) == [hotel.id])
  }

  @Test func currentAccoladesGroupAndSortByNativeOrderWithoutMergingSources() {
    let three = idea("Three")
    let two = idea("Two")
    let one = idea("One")
    let score = idea("Score")
    let stale = idea("Stale")
    let sameDisplayDifferentSource = idea("Different source")
    let evaluations = [
      evaluation(for: one, display: "★", number: 1),
      evaluation(for: two, display: "★★", number: 2),
      evaluation(for: three, display: "★★★", number: 3),
      evaluation(for: score, source: "Harper", display: "96/100", number: 96, kind: .numericScore),
      evaluation(for: stale, display: "★", number: 1, staleness: .stale),
      evaluation(for: sameDisplayDifferentSource, source: "Another Guide", display: "★★", number: 2),
    ]
    let built = guide([three, two, one, score, stale, sameDisplayDifferentSource], evaluations: evaluations)
    #expect(built.sections.map(\.title) == [
      "Michelin Guide · ★★★", "Another Guide · ★★", "Michelin Guide · ★★",
      "Michelin Guide · ★", "Harper · 96/100", "Other places",
    ])
    #expect(built.sections.last?.cards.map(\.idea.id) == [stale.id])
  }

  @Test func matchesSortFirstAndNotesAreNewestWithCount() {
    let neutral = idea("Alpha")
    let match = idea("Zulu")
    let evaluations = [evaluation(for: neutral), evaluation(for: match)]
    let notes = (0..<3).map { index in
      TasteNote(
        id: UUID(), travelPartyID: partyID, plannerID: planners[0].id, ideaID: match.id,
        placeName: match.name, body: "Note \(index)", notedAt: Date(timeIntervalSince1970: Double(index))
      )
    }
    let built = guide(
      [neutral, match], evaluations: evaluations,
      interests: [interest(match, planners[0], .wantToDo), interest(match, planners[1], .mustDo)],
      notes: notes
    )
    #expect(built.sections.first?.cards.map(\.idea.id) == [match.id, neutral.id])
    let matchCard = built.sections.first?.cards.first
    #expect(matchCard?.latestNote?.body == "Note 2")
    #expect(matchCard?.noteCount == 3)
    #expect(built.counts[.noted] == 1)
  }

  @Test func notedShelfExcludesPlacesHiddenOnNotForMe() {
    let place = idea("Hated restaurant")
    let note = TasteNote(
      id: UUID(), travelPartyID: partyID, plannerID: planners[0].id, ideaID: place.id,
      placeName: place.name, body: "We won't return.", notedAt: Date(timeIntervalSince1970: 1)
    )
    let built = guide(
      [place], interests: [interest(place, planners[0], .doNotDo)], notes: [note])
    #expect(built.counts[.all] == 0)
    #expect(built.counts[.noted] == 0)
    #expect(built.counts[.notForMe] == 1)
  }

  @Test func initialScopeUsesEveryEntryRuleBranch() {
    let selected = MapRegion(id: UUID(), name: "Selected", centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1)
    let tripRegion = MapRegion(id: UUID(), name: "Trip", centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1)
    let fallback = MapRegion(id: UUID(), name: "Last", centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1)
    let paris = MapRegion(id: UUID(), name: "Paris", centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1)
    let lyon = MapRegion(id: UUID(), name: "Lyon", centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1)

    #expect(RegionGuideScope(selectedRegion: selected, activeTripRegions: [tripRegion], lastGuideRegion: fallback, selectedKindGroups: [.stay]) == RegionGuideScope(region: selected, category: .hotels))
    #expect(RegionGuideScope(selectedRegion: nil, activeTripRegions: [tripRegion], lastGuideRegion: fallback, selectedKindGroups: [.food]) == RegionGuideScope(region: tripRegion, category: .dining))
    #expect(RegionGuideScope(selectedRegion: nil, activeTripRegions: [tripRegion, selected], lastGuideRegion: fallback, selectedKindGroups: [.stay, .food]) == RegionGuideScope(region: fallback, category: .dining))
    #expect(RegionGuideScope(selectedRegion: nil, activeTripRegions: [lyon], lastGuideRegion: paris, selectedKindGroups: []) == RegionGuideScope(region: lyon, category: .dining))
    #expect(RegionGuideScope(selectedRegion: nil, activeTripRegions: [], lastGuideRegion: nil, selectedKindGroups: []) == RegionGuideScope(region: nil, category: .dining))
  }
}
