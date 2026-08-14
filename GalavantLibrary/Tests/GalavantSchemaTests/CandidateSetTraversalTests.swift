import Foundation
import GalavantSchema
import Testing

@Suite struct CandidateSetTraversalTests {
  private func candidate(
    _ id: UUID,
    rank: Int,
    resolved: Bool = false
  ) -> TripIdea {
    TripIdea(
      id: id,
      tripID: UUID(),
      ideaID: resolved ? UUID() : nil,
      inlineTitle: id.uuidString,
      status: .considering,
      shortlistRank: rank
    )
  }

  @Test func activeIsTotalForANonemptySetAndFallsBackToCanonicalOrder() {
    let first = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let second = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let traversal = CandidateSetTraversal(candidates: [
      candidate(second, rank: 2),
      candidate(first, rank: 1),
    ])

    #expect(traversal.active(preferredID: nil) == first)
    #expect(traversal.active(preferredID: second) == second)
    #expect(traversal.active(preferredID: UUID()) == first)
  }

  @Test func nextWrapsInCanonicalOrder() {
    let first = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let second = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let traversal = CandidateSetTraversal(candidates: [
      candidate(second, rank: 2),
      candidate(first, rank: 1),
    ])

    #expect(traversal.next(after: first) == second)
    #expect(traversal.next(after: second) == first)
  }

  @Test func processingReselectsTheCanonicalSuccessorAndEndsOnlyWhenTheSetIsEmpty() {
    let first = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let second = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let third = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
    let traversal = CandidateSetTraversal(candidates: [
      candidate(third, rank: 3),
      candidate(first, rank: 1),
      candidate(second, rank: 2),
    ])

    #expect(traversal.activeAfterProcessing(second) == third)
    #expect(traversal.activeAfterProcessing(third) == first)
    #expect(CandidateSetTraversal(candidates: [candidate(first, rank: 1)]).activeAfterProcessing(first) == nil)
  }

  @Test func markerStateKeepsFuzzyAndResolvedLayersDistinct() {
    let active = candidate(UUID(), rank: 0)
    let resolved = candidate(UUID(), rank: 1, resolved: true)

    #expect(CandidateMapMarkerState.state(for: active, activeID: active.id) == .fuzzy(isActive: true))
    #expect(CandidateMapMarkerState.state(for: resolved, activeID: active.id) == .resolved(isActive: false))
  }

  @Test func browserTargetSearchesOnlyTheUnresolvedCandidateHint() {
    let candidate = TripCandidate(name: "Neustift Abbey", searchHint: "Neustift Abbey South Tyrol")

    #expect(
      BrowserTargetDerivation.target(for: candidate, resolution: .unresolved)
        == .search(query: "Neustift Abbey South Tyrol")
    )
  }

  @Test func browserTargetUsesTheResolvedPlacesOfficialWebsite() {
    let candidate = TripCandidate(name: "Neustift Abbey", searchHint: "AI supplied search hint")
    let officialURL = URL(string: "https://www.kloster-neustift.it")!

    #expect(
      BrowserTargetDerivation.target(
        for: candidate,
        resolution: .resolved(officialURL: officialURL)
      ) == .website(officialURL)
    )
  }

  @Test func resolveReconcileHasNoCollisionForTheOnlyTripRow() {
    let ideaID = UUID()
    let candidate = TripIdea(
      id: UUID(), tripID: UUID(), ideaID: ideaID,
      inlineNote: "Great after the market.", status: .considering)

    let reconcile = ResolveReconcile(
      tripIdeas: [candidate], resolvedIdeaID: ideaID, candidateID: candidate.id)

    #expect(reconcile.collision == nil)
  }

  @Test func resolveReconcilePreservesBothNotesWhenMergingADuplicate() {
    let tripID = UUID()
    let ideaID = UUID()
    let existing = TripIdea(
      id: UUID(), tripID: tripID, ideaID: ideaID,
      inlineNote: "Already on the shortlist.", status: .shortlisted)
    let candidate = TripIdea(
      id: UUID(), tripID: tripID, ideaID: ideaID,
      inlineNote: "A useful rainy-day alternative.", status: .considering)

    let collision = ResolveReconcile(
      tripIdeas: [candidate, existing], resolvedIdeaID: ideaID, candidateID: candidate.id
    ).collision

    #expect(collision?.existingID == existing.id)
    #expect(collision?.duplicateID == candidate.id)
    #expect(collision?.mergedInlineNote == "Already on the shortlist.\n\nA useful rainy-day alternative.")
    #expect(
      collision?.action(for: .merge)
        == .merge(
          existingID: existing.id,
          duplicateID: candidate.id,
          inlineNote: "Already on the shortlist.\n\nA useful rainy-day alternative."
        )
    )
  }

  @Test func resolveReconcileRepresentsKeepingBothRows() {
    let tripID = UUID()
    let ideaID = UUID()
    let existing = TripIdea(id: UUID(), tripID: tripID, ideaID: ideaID, status: .scheduled)
    let candidate = TripIdea(id: UUID(), tripID: tripID, ideaID: ideaID, status: .considering)

    let collision = ResolveReconcile(
      tripIdeas: [existing, candidate], resolvedIdeaID: ideaID, candidateID: candidate.id
    ).collision

    #expect(collision?.action(for: .keepBoth) == .keepBoth)
  }
}
