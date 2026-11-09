import Foundation
import GalavantSchema
import Testing

@Suite struct IdeaDossierTests {
  let partyID = UUID()

  @Test func projectsEveryPlannerAndConvergesDuplicateInterestRows() {
    let ideaID = UUID()
    let jon = Planner(id: UUID(), displayName: "Jon", travelPartyID: partyID)
    let wendy = Planner(id: UUID(), displayName: "Wendy", travelPartyID: partyID)
    let jonSurvivorID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let jonLoserID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let rows = [
      IdeaInterest(id: jonLoserID, ideaID: ideaID, plannerID: jon.id, level: .wantToDo),
      IdeaInterest(id: jonSurvivorID, ideaID: ideaID, plannerID: jon.id, level: .mustDo),
    ]
    let dossier = IdeaDossier(
      idea: Idea(id: ideaID), evaluations: [], interests: rows, planners: [wendy, jon], notes: [],
      tags: [], ideaTags: [], photos: [], knownIdeaIDs: [ideaID])
    #expect(dossier.interests.map(\.planner.displayName) == ["Jon", "Wendy"])
    #expect(dossier.interests.count == 2)
    #expect(dossier.interests[0].level == .mustDo)
    #expect(dossier.interests[1].level == nil)
  }

  @Test func standingUsesInterestProjection() {
    let idea = Idea(id: UUID())
    func dossier(_ levels: [Interest?]) -> IdeaDossier {
      let planners = levels.enumerated().map { index, _ in Planner(id: UUID(), displayName: "\(index)") }
      let interests = zip(planners, levels).compactMap { planner, level in
        level.map { IdeaInterest(id: UUID(), ideaID: idea.id, plannerID: planner.id, level: $0) }
      }
      return IdeaDossier(
        idea: idea, evaluations: [], interests: interests, planners: planners, notes: [],
        tags: [], ideaTags: [], photos: [], knownIdeaIDs: [idea.id])
    }
    #expect(dossier([.wantToDo, .mustDo]).standing == Interest.standing([.wantToDo, .mustDo]))
    #expect(dossier([.wantToDo, nil]).standing == Interest.standing([.wantToDo, nil]))
    #expect(dossier([.doNotDo, .doNotDo]).standing == Interest.standing([.doNotDo, .doNotDo]))
  }

  @Test func accoladesSplitCurrentAndHistoricalAndDropOrphans() {
    let ideaID = UUID()
    let orphanID = UUID()
    func evaluation(_ id: UUID, _ target: UUID, _ staleness: EvaluationStaleness) -> IdeaEvaluation {
      IdeaEvaluation(
        id: id, travelPartyID: partyID, ideaID: target, sourceName: "Guide", kind: .stars,
        nativeValueText: "3", nativeDisplay: "★★★", recordedAt: Date(), confidence: .official,
        staleness: staleness)
    }
    let dossier = IdeaDossier(
      idea: Idea(id: ideaID),
      evaluations: [evaluation(UUID(), ideaID, .current), evaluation(UUID(), ideaID, .historical), evaluation(UUID(), orphanID, .current)],
      interests: [], planners: [], notes: [], tags: [], ideaTags: [], photos: [], knownIdeaIDs: [ideaID])
    #expect(dossier.accolades.current.count == 1)
    #expect(dossier.accolades.historical.count == 1)
  }

  @Test func notesPlacementUsesEachVisitedSignal() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    func day(_ day: Int) -> Date {
      calendar.date(from: DateComponents(year: 2025, month: 1, day: day))!
    }
    let now = day(10)
    let ideaID = UUID()
    let tripID = UUID()
    let trip = Trip(id: tripID, startDate: day(9))
    func placement(_ idea: Idea, _ stops: [TripIdea] = [], _ trips: [Trip] = []) -> NotesPlacement {
      IdeaDossier(
        idea: idea, evaluations: [], interests: [], planners: [], notes: [], tags: [], ideaTags: [],
        photos: [], knownIdeaIDs: [idea.id], stops: stops, trips: trips, now: now, calendar: calendar
      ).notesPlacement
    }

    #expect(placement(Idea(id: ideaID, visited: true)) == .top)
    #expect(placement(Idea(id: ideaID), [TripIdea(
      id: UUID(), tripID: tripID, ideaID: ideaID, completedAt: now
    )]) == .top)
    #expect(placement(Idea(id: ideaID), [TripIdea(
      id: UUID(), tripID: tripID, ideaID: ideaID, status: .scheduled, dayNumber: 1
    )], [trip]) == .top)
    #expect(placement(Idea(id: ideaID), [TripIdea(
      id: UUID(), tripID: tripID, ideaID: ideaID, status: .scheduled, dayNumber: 3
    )], [trip]) == .bottom)
    #expect(placement(Idea(id: ideaID), [TripIdea(
      id: UUID(), tripID: tripID, ideaID: ideaID, status: .scheduled, dayNumber: 1, skippedAt: now
    )], [trip]) == .bottom)
    #expect(placement(Idea(id: ideaID), [TripIdea(
      id: UUID(), tripID: tripID, ideaID: ideaID, status: .scheduled, dayNumber: 1
    )]) == .bottom)
  }

  @Test func notesSurviveMissingIdeaAssociationsAndPhotosExcludeHeader() {
    let ideaID = UUID()
    let olderNote = TasteNote(
      id: UUID(), travelPartyID: partyID, ideaID: ideaID, placeName: "Place", body: "First visit",
      notedAt: .distantPast)
    let newerNote = TasteNote(
      id: UUID(), travelPartyID: partyID, ideaID: ideaID, placeName: "Place", body: "Loved it",
      notedAt: .distantFuture)
    let headerID = UUID()
    let earlier = UUID()
    let later = UUID()
    let photos: [(id: UUID, ideaID: UUID, thumbnail: Data, sortRank: Int, isHeader: Bool)] = [
      (later, ideaID, Data([2]), 2, false),
      (headerID, ideaID, Data([0]), 0, true),
      (earlier, ideaID, Data([1]), 1, false),
    ]
    let dossier = IdeaDossier(
      idea: Idea(id: ideaID), evaluations: [], interests: [], planners: [], notes: [olderNote, newerNote],
      tags: [], ideaTags: [], photos: photos, knownIdeaIDs: [ideaID])
    #expect(dossier.notes.map(\.id) == [newerNote.id, olderNote.id])
    #expect(dossier.photos.map(\.id) == [earlier, later])
    #expect(dossier.photos.map(\.thumbnail) == [Data([1]), Data([2])])
  }
}
