import Dependencies
import Foundation
import GalavantAI
import GalavantSchema
import SQLiteData

/// The external-LLM recommendation handoff surface (ADR-0036): export a brief,
/// paste the round-tripped result back as reviewable candidates, and commit the
/// ones worth keeping as `.considering` trip ideas. Split out of the core planning
/// model so it stays focused on trip state; the contract, routing, and decode all
/// live in the tested schema core.
struct RecommendationHandoffPresentation: Identifiable {
  let session: HandoffSession
  var id: HandoffSession.ID { session.id }
}

struct RecommendationWorkspacePresentation: Identifiable {
  let sessionID: HandoffSession.ID
  var id: HandoffSession.ID { sessionID }
}

struct RecommendationCandidateDraft: Identifiable {
  let id: UUID
  var name: String
  var locality: String
  var searchHint: String
  var why: String
  var fit: String
  var visit: String
  let dayRef: String?
  let placementAfter: String?
  let priority: Int?

  init(candidate: TripCandidate) {
    id = candidate.id
    name = candidate.name ?? ""
    locality = candidate.locality ?? ""
    searchHint = candidate.searchHint ?? ""
    why = candidate.why ?? ""
    fit = candidate.fit ?? ""
    visit = candidate.visit ?? ""
    dayRef = candidate.dayRef
    placementAfter = candidate.placementAfter
    priority = candidate.priority
  }

  var candidate: TripCandidate {
    TripCandidate(
      id: id,
      name: name,
      locality: locality,
      searchHint: searchHint,
      why: why,
      fit: fit,
      visit: visit,
      priority: priority,
      dayRef: dayRef,
      placementAfter: placementAfter
    )
  }

  var canCommit: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension TripPlanningModel {
  func startRecommendationHandoff() {
    guard let trip else { return }
    let scope = RecommendationHandoffScope.trip
    let promptSession = HandoffSession(
      sourceType: scope.sourceType,
      sourceID: trip.id,
      taskType: RecommendationHandoffTask.candidatePlaces,
      scopeKey: scope.scopeKey,
      exportedPrompt: ""
    )
    let session = HandoffSession(
      id: promptSession.id,
      sourceType: promptSession.sourceType,
      sourceID: promptSession.sourceID,
      taskType: promptSession.taskType,
      scopeKey: promptSession.scopeKey,
      createdAt: promptSession.createdAt,
      exportedPrompt: RecommendationHandoffContract.brief(
        session: promptSession,
        tripName: trip.name,
        tripNotes: trip.notes,
        plan: plan
      )
    )
    do {
      try handoffSessionStore.save(session)
      recommendationReview = []
      recommendationHandoffWarning = nil
      destination = .recommendationHandoff(RecommendationHandoffPresentation(session: session))
    } catch {
      recommendationHandoffError = error.localizedDescription
    }
  }

  func pasteRecommendationResult(_ strings: [String], for session: HandoffSession) {
    guard let pasted = strings.first else { return }
    do {
      var warnings: [String] = []

      // The handoff token is a routing hint, not an admission ticket. A dropped or
      // mismatched token attaches the result to the handoff you're pasting into
      // rather than rejecting it — commit always targets this trip regardless of
      // which session recorded the candidates, so the blast radius is bookkeeping.
      let bodyText: String
      if let routed = try? HandoffRouting.route(pasted) {
        bodyText = routed.text
        if routed.sessionID != session.id {
          warnings.append("This result was tagged for a different recommendation handoff — added it to this one anyway.")
        }
      } else {
        bodyText = pasted
        warnings.append("This result had no Galavant handoff token — added it to this handoff anyway.")
      }

      let contract = try RecommendationHandoffContract.marker.strippingMarker(from: bodyText)
      if let warning = contract.warning { warnings.append(warning) }
      let candidates = try TripCandidate.decodeReturn(contract.text)
      var updatedSession = session
      try updatedSession.storeRecommendationCandidates(candidates)
      try handoffSessionStore.save(updatedSession)
      recommendationReview = candidates.map(RecommendationCandidateDraft.init(candidate:))
      recommendationHandoffWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n\n")
    } catch {
      recommendationHandoffError = error.localizedDescription
    }
  }

  func commitRecommendationCandidate(_ candidate: RecommendationCandidateDraft, from session: HandoffSession) {
    guard candidate.canCommit else { return }
    withErrorReporting {
      let committed = try database.write { db in
        try TripIdea.commit(candidate: candidate.candidate, into: tripID, in: db)
      }
      var updatedSession = handoffSessionStore.session(session.id) ?? session
      // `.imported` records that this session has produced a durable row, rather
      // than claiming every row in its review sheet has been consumed.
      updatedSession.importedAt = .now
      updatedSession.status = .imported
      try updatedSession.replaceRecommendationCandidate(candidate.candidate)
      updatedSession.link(candidateID: candidate.id, to: committed.id)
      try handoffSessionStore.save(updatedSession)
      recommendationReview.removeAll { $0.id == candidate.id }
    }
  }

  var mostRecentRecommendationWorkspaceSession: HandoffSession? {
    handoffSessionStore.sessions()
      .filter {
          $0.sourceID == tripID
          && $0.taskType == RecommendationHandoffTask.candidatePlaces
          && $0.hasCommittedRecommendationCandidates
      }
      .max { $0.createdAt < $1.createdAt }
  }

  func recommendationWorkspaceButtonTapped(sessionID: HandoffSession.ID) {
    destination = .recommendationWorkspace(RecommendationWorkspacePresentation(sessionID: sessionID))
  }

  func recommendationWorkspaceIsAvailable(for sessionID: HandoffSession.ID) -> Bool {
    handoffSessionStore.session(sessionID)?.hasCommittedRecommendationCandidates ?? false
  }
}
