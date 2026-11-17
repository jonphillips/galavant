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

  @Test func rankedListsGroupNamedRanksAndKeepTheirBestMemberRanks() {
    let tripID = UUID()
    let firstID = UUID()
    let secondID = UUID()
    let otherRegionID = UUID()
    func entry(
      _ ideaID: Idea.ID?, priority: Int?, name: String?, status: TripIdeaStatus = .considering,
      priorityOutOf: Int? = 5, alternativeGroupID: UUID? = nil
    ) -> TripIdea {
      TripIdea(
        id: UUID(), tripID: tripID, ideaID: ideaID,
        rationalePriority: priority, rationalePriorityOutOf: priorityOutOf,
        rationalePriorityList: name, status: status, alternativeGroupID: alternativeGroupID)
    }

    let entries = [
      entry(firstID, priority: 4, name: "Dim Sum", status: .scheduled),
      entry(firstID, priority: 2, name: "Dim Sum", alternativeGroupID: UUID()),
      entry(secondID, priority: 1, name: "Dim Sum"),
      entry(otherRegionID, priority: 1, name: "Manchester Hotels"),
      entry(UUID(), priority: 1, name: nil),
      entry(UUID(), priority: nil, name: "Dim Sum"),
      entry(nil, priority: 1, name: "Dim Sum"),
    ]

    let lists = TripIdea.rankedLists(entries: entries)
    #expect(lists.map(\.name) == ["Dim Sum", "Manchester Hotels"])
    #expect(lists[0].members.map(\.ideaID) == [secondID, firstID])
    #expect(lists[0].members[0].priority == 1)
    #expect(lists[0].members[0].isOpenChoice)
    #expect(lists[0].members[1].priority == 2)
    #expect(lists[0].members[1].isOpenChoice)
  }
}
