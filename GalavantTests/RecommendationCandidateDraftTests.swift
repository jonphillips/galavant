import GalavantSchema
import Testing

@testable import Galavant

struct RecommendationCandidateDraftTests {
  @Test func preservesTheRankedListNameWhenAReviewedCandidateIsCommitted() {
    let draft = RecommendationCandidateDraft(candidate: TripCandidate(
      name: "Cafe", priority: 2, priorityOutOf: 5, list: "Soho Indian"))

    #expect(draft.candidate.list == "Soho Indian")
    #expect(draft.candidate.priority == 2)
  }
}
