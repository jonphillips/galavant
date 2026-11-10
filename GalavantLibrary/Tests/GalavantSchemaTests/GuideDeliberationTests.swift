import Foundation
import GalavantSchema
import Testing

@Suite struct GuideDeliberationTests {
  @Test func openChoiceRanksKeepBestRankOnlyForOpenPlaces() {
    let kept = UUID()
    let tied = UUID()
    let tripID = UUID()
    func entry(
      _ ideaID: Idea.ID?, status: TripIdeaStatus = .considering, priority: Int?, outOf: Int? = 5,
      alternativeGroupID: UUID? = nil
    ) -> TripIdea {
      TripIdea(
        id: UUID(), tripID: tripID, ideaID: ideaID, rationalePriority: priority,
        rationalePriorityOutOf: outOf, status: status, alternativeGroupID: alternativeGroupID)
    }

    let entries = [
      entry(kept, priority: 3),
      entry(kept, status: .shortlisted, priority: 1),
      entry(kept, status: .scheduled, priority: 2),
      entry(kept, status: .declined, priority: 1),
      entry(kept, status: .shortlisted, priority: 2, alternativeGroupID: UUID()),
      entry(tied, priority: 1, outOf: 1),
      entry(tied, priority: 4),
      entry(nil, priority: 1),
      TripIdea.freeform(id: UUID(), tripID: tripID, title: "Train", note: nil, shortlistRank: 0),
    ]

    #expect(TripIdea.openChoiceRanks(entries: entries) == [kept: ChatRank(priority: 2, priorityOutOf: 5)])
    #expect(TripIdea.considering(entries).allSatisfy(TripIdea.isConsidering))
  }
}
