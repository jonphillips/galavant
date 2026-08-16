import Dependencies
import Foundation
import GalavantAI
import GalavantPlaces
import GalavantSchema
import SQLiteData

private struct DismissedRecommendationCandidate {
  let tripIdea: TripIdea
  let alternativeMemberIDs: [TripIdea.ID]
  let activeAlternativeID: TripIdea.ID?
}

@MainActor
@Observable
final class RecommendationWorkspaceModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.handoffSessionStore) private var handoffSessionStore
  @ObservationIgnored @Dependency(\.placeMatcher) private var placeMatcher
  @ObservationIgnored @FetchAll(TripIdea.all) var allTripIdeas
  @ObservationIgnored @FetchAll(Idea.all) var ideas
  @ObservationIgnored @FetchAll(TripStay.all) var allTripStays
  @ObservationIgnored @FetchAll(TripRegion.all) var allTripRegions
  @ObservationIgnored @FetchAll(MapRegion.all) var regions
  @ObservationIgnored @FetchAll(Trip.all) var trips

  let tripID: Trip.ID
  let sessionID: HandoffSession.ID
  var activeCandidateID: TripIdea.ID?
  var choiceCandidateIDs: Set<TripIdea.ID> = []
  var resolveResults: [Place] = []
  var pendingReconcile: ResolveReconcile.Collision?
  var handoffCandidates: [TripCandidate] = []
  var candidateLinks: [HandoffCandidateLink] = []
  private(set) var hasLoadedCandidateSet = false

  init(tripID: Trip.ID, sessionID: HandoffSession.ID) {
    self.tripID = tripID
    self.sessionID = sessionID
  }

  func task() {
    loadCandidateSet()
    activeCandidateID = effectiveActiveCandidateID
  }

  func candidateTapped(_ candidate: RecommendationWorkspaceCandidate) {
    activeCandidateID = candidate.id
    resolveResults = []
    pendingReconcile = nil
  }

  /// Add a candidate the AI didn't supply. It enters the set exactly like a pulled
  /// AI candidate — a committed `.considering` freeform stop, linked into this
  /// session — so it resolves on the map and processes through the same actions.
  func addManualCandidate(named name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    withErrorReporting {
      let candidate = TripCandidate(name: trimmed)
      let committed = try database.write { db in
        try TripIdea.commit(candidate: candidate, into: tripID, in: db)
      }
      guard var session = handoffSessionStore.session(sessionID) else { return }
      var stored = (try? session.recommendationCandidates()) ?? []
      stored.append(candidate)
      try session.storeRecommendationCandidates(stored)
      session.link(candidateID: candidate.id, to: committed.id)
      session.importedAt = .now
      session.status = .imported
      try handoffSessionStore.save(session)
      handoffCandidates = stored
      candidateLinks = session.candidateLinks
      activeCandidateID = committed.id
      resolveResults = []
    }
  }

  func saveButtonTapped(_ candidate: RecommendationWorkspaceCandidate) {
    let nextCandidateID = nextCandidateAfterProcessing(candidate.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.setStatus(.shortlisted, stopID: candidate.id, in: db)
      }
      choiceCandidateIDs.remove(candidate.id)
      activeCandidateID = nextCandidateID
      resolveResults = []
    }
  }

  /// An unresolved candidate is already the freeform stop that ADR-0010 calls
  /// for; scheduling that row preserves its rationale and lets later resolution
  /// upgrade it in place to an idea-backed stop.
  func addToItineraryButtonTapped(_ candidate: RecommendationWorkspaceCandidate) {
    let nextCandidateID = nextCandidateAfterProcessing(candidate.id)
    withErrorReporting {
      try database.write { db in
        try TripIdea.scheduleUnplaced(stopID: candidate.id, in: db)
      }
      choiceCandidateIDs.remove(candidate.id)
      activeCandidateID = nextCandidateID
      resolveResults = []
    }
  }

  /// Place a candidate on a specific day (or the To-Be-Scheduled bucket when `day`
  /// is nil) straight from Evaluate — the decision made here instead of deferred to
  /// the itinerary. An unresolved candidate lands as a dated freeform stop that later
  /// resolution upgrades in place (ADR-0010); a resolved one becomes a normal stop.
  func addToDay(_ candidate: RecommendationWorkspaceCandidate, day: Int?) {
    let nextCandidateID = nextCandidateAfterProcessing(candidate.id)
    withErrorReporting {
      try database.write { db in
        if let day {
          try TripIdea.schedule(.day(day), stopID: candidate.id, in: db)
        } else {
          try TripIdea.scheduleUnplaced(stopID: candidate.id, in: db)
        }
      }
      choiceCandidateIDs.remove(candidate.id)
      activeCandidateID = nextCandidateID
      resolveResults = []
    }
  }

  func dismissButtonTapped(_ candidate: RecommendationWorkspaceCandidate, undoManager: UndoManager?) {
    withErrorReporting {
      let dismissal = try database.read { db -> DismissedRecommendationCandidate? in
        guard let tripIdea = try TripIdea.find(candidate.id).fetchOne(db) else { return nil }
        let alternatives: [TripIdea]
        if let groupID = tripIdea.alternativeGroupID {
          alternatives = try TripIdea.where { $0.tripID.eq(tripIdea.tripID) }
            .fetchAll(db)
            .filter { $0.alternativeGroupID == groupID }
        } else {
          alternatives = [tripIdea]
        }
        return DismissedRecommendationCandidate(
          tripIdea: tripIdea,
          alternativeMemberIDs: alternatives.map(\.id),
          activeAlternativeID: alternatives.first(where: \.isActive)?.id
        )
      }
      guard let dismissal else { return }
      let nextCandidateID = nextCandidateAfterProcessing(candidate.id)
      try database.write { db in
        try TripIdea.remove(stopID: candidate.id, in: db)
      }
      choiceCandidateIDs.remove(candidate.id)
      activeCandidateID = nextCandidateID
      resolveResults = []
      undoManager?.registerUndo(withTarget: self) { model in
        model.restoreDismissedCandidate(dismissal)
      }
      undoManager?.setActionName("Dismiss Candidate")
    }
  }

  func choiceButtonTapped(_ candidate: RecommendationWorkspaceCandidate) {
    if choiceCandidateIDs.contains(candidate.id) {
      choiceCandidateIDs.remove(candidate.id)
    } else {
      choiceCandidateIDs.insert(candidate.id)
    }
  }

  func chooseOneButtonTapped() {
    guard
      let effectiveActiveCandidateID,
      choiceCandidateIDs.count > 1,
      choiceCandidateIDs.contains(effectiveActiveCandidateID)
    else {
      return
    }
    withErrorReporting {
      try database.write { db in
        _ = try TripIdea.chooseOne(
          among: Array(choiceCandidateIDs),
          activeStopID: effectiveActiveCandidateID,
          in: db
        )
      }
      choiceCandidateIDs = []
    }
  }

  func useThisPlaceButtonTapped() async {
    guard let activeCandidate else { return }
    resolveResults = await placeMatcher.matches(for: activeCandidate.candidate, in: tripRegions)
  }

  func resolveResultTapped(_ place: Place) {
    guard let activeCandidate else { return }
    withErrorReporting {
      pendingReconcile = try database.write { db in
        guard let resolvedIdeaID = try RecommendationResolution.confirm(
          candidateStopID: activeCandidate.id,
          place: place,
          in: db
        ) else { return nil }
        let tripIdeas = try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db)
        return ResolveReconcile(
          tripIdeas: tripIdeas,
          resolvedIdeaID: resolvedIdeaID,
          candidateID: activeCandidate.id
        ).collision
      }
      resolveResults = []
    }
  }

  func resolveReconcileChoice(_ choice: ResolveReconcile.Choice) {
    guard let collision = pendingReconcile else { return }
    let action = collision.action(for: choice)
    let nextCandidateID = nextCandidateAfterProcessing(collision.duplicateID)
    withErrorReporting {
      try database.write { db in
        guard case let .merge(existingID, duplicateID, inlineNote) = action else { return }
        try TripIdea.find(existingID)
          .update { $0.inlineNote = #bind(inlineNote) }
          .execute(db)
        try TripIdea.remove(stopID: duplicateID, in: db)
      }
      pendingReconcile = nil
      if case .merge = action {
        choiceCandidateIDs.remove(collision.duplicateID)
        activeCandidateID = nextCandidateID
      }
    }
  }

  private func loadCandidateSet() {
    defer { hasLoadedCandidateSet = true }
    guard let session = handoffSessionStore.session(sessionID) else {
      handoffCandidates = []
      candidateLinks = []
      return
    }
    handoffCandidates = (try? session.recommendationCandidates()) ?? []
    candidateLinks = session.candidateLinks
  }

  private func restoreDismissedCandidate(_ dismissal: DismissedRecommendationCandidate) {
    withErrorReporting {
      try database.write { db in
        try TripIdea.insert { TripIdea.Draft(dismissal.tripIdea) }.execute(db)
        guard
          let groupID = dismissal.tripIdea.alternativeGroupID,
          let activeID = dismissal.activeAlternativeID,
          try TripIdea.restoreAlternativeRing(
            memberIDs: dismissal.alternativeMemberIDs,
            activeStopID: activeID,
            groupID: groupID,
            in: db
          )
        else {
          try TripIdea.find(dismissal.tripIdea.id)
            .update {
              $0.alternativeGroupID = #bind(nil)
              $0.isActive = #bind(true)
            }
            .execute(db)
          return
        }
      }
      activeCandidateID = dismissal.tripIdea.id
    }
  }
}
