import Dependencies
import Foundation
import GalavantAI
import GalavantPlaces
import GalavantSchema
import SQLiteData

/// The external-LLM recommendation handoff surface (ADR-0036): export a brief,
/// paste the round-tripped result back as reviewable candidates, and commit the
/// ones worth keeping as `.considering` trip ideas. Split out of the core planning
/// model so it stays focused on trip state; the contract, routing, and decode all
/// live in the tested schema core.
struct RecommendationHandoffPresentation: Identifiable {
  let session: HandoffSession
  let seedReview: SeedReviewModel?
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
  let list: String?
  let bookAhead: Bool?

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
    list = candidate.list
    bookAhead = candidate.bookAhead
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
      list: list,
      dayRef: dayRef,
      placementAfter: placementAfter,
      bookAhead: bookAhead
    )
  }

  var canCommit: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension TripPlanningModel {
  func startSeedHandoff() {
    guard let trip else { return }
    let scope = RecommendationHandoffScope.trip
    let promptSession = HandoffSession(
      sourceType: scope.sourceType, sourceID: trip.id,
      taskType: RecommendationHandoffTask.seedTrip, scopeKey: scope.scopeKey, exportedPrompt: ""
    )
    let session = HandoffSession(
      id: promptSession.id, sourceType: promptSession.sourceType,
      sourceID: promptSession.sourceID, taskType: promptSession.taskType,
      scopeKey: promptSession.scopeKey, createdAt: promptSession.createdAt,
      exportedPrompt: RecommendationHandoffContract.seedBrief(
        session: promptSession, tripName: trip.name, plan: plan,
        tasteLines: tasteLines(for: trip)
      )
    )
    do {
      try handoffSessionStore.save(session)
      resetHandoffPasteState()
      destination = .recommendationHandoff(RecommendationHandoffPresentation(session: session, seedReview: SeedReviewModel()))
    } catch {
      recommendationHandoffError = error.localizedDescription
    }
  }

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
        plan: plan,
        tasteLines: tasteLines(for: trip)
      )
    )
    do {
      try handoffSessionStore.save(session)
      resetHandoffPasteState()
      destination = .recommendationHandoff(RecommendationHandoffPresentation(session: session, seedReview: nil))
    } catch {
      recommendationHandoffError = error.localizedDescription
    }
  }

  private func resetHandoffPasteState() {
    recommendationReview = []
    recommendationHandoffPaste.warning = nil
    recommendationHandoffPaste.note = nil
    recommendationHandoffPaste.noteSaved = false
    recommendationHandoffError = nil
  }

  private func tasteLines(for trip: Trip) -> [String] {
    guard let partyID = trip.travelPartyID else { return [] }
    return (try? database.read { db in
      let profiles = try TravelProfile.where { $0.travelPartyID.eq(partyID) }.fetchAll(db)
      let planners = try Planner.where { $0.travelPartyID.eq(partyID) }.fetchAll(db)
      let profileLines = TravelProfile.promptLinesByParty([partyID], profiles: profiles, planners: planners)[partyID] ?? []
      let notes = try TasteNote.where { $0.travelPartyID.eq(partyID) }.fetchAll(db)
      return profileLines + TasteNote.promptLines(notes: notes, planners: planners)
    }) ?? []
  }

  func presentStagedSeed(
    _ seed: SeedReturn, for session: HandoffSession, context: SeedPlanContext,
    onCommitted: @escaping () -> Void
  ) {
    resetHandoffPasteState()
    let review = SeedReviewModel(onCommitted: onCommitted)
    review.prepareReview(seed, context: context)
    destination = .recommendationHandoff(RecommendationHandoffPresentation(session: session, seedReview: review))
  }

  func pasteButtonTapped(_ pasted: String?) {
    if case let .recommendationHandoff(presentation)? = destination {
      pasteRecommendationResult(pasted, for: presentation.session, seedReviewModel: presentation.seedReview)
      return
    }
    let routed = pasted.flatMap { try? HandoffRouting.route($0) }
    if let routed, let session = handoffSessionStore.session(routed.sessionID), session.sourceID == tripID {
      resetHandoffPasteState()
      let presentation = RecommendationHandoffPresentation(
        session: session,
        seedReview: session.taskType == RecommendationHandoffTask.seedTrip ? SeedReviewModel() : nil
      )
      destination = .recommendationHandoff(presentation)
    } else if HandoffReturnKind.classify(routed?.text ?? pasted ?? "") == .seedTrip {
      startSeedHandoff()
    } else {
      startRecommendationHandoff()
    }
    guard case let .recommendationHandoff(presentation)? = destination else { return }
    pasteRecommendationResult(pasted, for: presentation.session, seedReviewModel: presentation.seedReview)
  }

  func pasteRecommendationResult(
    _ pasted: String?, for session: HandoffSession, seedReviewModel: SeedReviewModel?
  ) {
    guard let pasted, !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      if session.taskType == RecommendationHandoffTask.seedTrip {
        seedReviewModel?.error = "Clipboard is empty. Copy a trip seed result, then paste it here."
      } else {
        recommendationHandoffPaste.warning = "Clipboard is empty. Copy a recommendation result, then paste it here."
      }
      return
    }
    let cleanPasted = StagedTripReturn.strippingTripLine(from: pasted)
    if session.taskType == RecommendationHandoffTask.seedTrip {
      seedReviewModel?.paste([cleanPasted], for: session, context: seedPlanContextSnapshot)
      return
    }
    do {
      var warnings: [String] = []

      // The handoff token is a routing hint, not an admission ticket. A dropped or
      // mismatched token attaches the result to the handoff you're pasting into
      // rather than rejecting it — commit always targets this trip regardless of
      // which session recorded the candidates, so the blast radius is bookkeeping.
      let bodyText: String
      if let routed = try? HandoffRouting.route(cleanPasted) {
        bodyText = routed.text
        if routed.sessionID != session.id {
          warnings.append("This result was tagged for a different recommendation handoff — added it to this one anyway.")
        }
      } else {
        bodyText = cleanPasted
        warnings.append("This result had no Galavant handoff token — added it to this handoff anyway.")
      }

      let contract = try RecommendationHandoffContract.marker.strippingMarker(from: bodyText)
      if let warning = contract.warning { warnings.append(warning) }
      let decoded = try TripCandidate.decodeReturn(contract.text)
      let candidates = decoded.candidates
      var updatedSession = handoffSessionStore.session(session.id) ?? session
      let merge = try updatedSession.storeRecommendationCandidates(candidates)
      try handoffSessionStore.save(updatedSession)
      try database.write { db in
        try RecommendationCandidateSet.applyReevaluation(
          merge, links: updatedSession.candidateLinks, in: db
        )
      }
      let linkedCandidateIDs = Set(
        updatedSession.candidateLinks.compactMap { link in
          link.tripIdeaID == nil ? nil : link.candidateID
        }
      )
      recommendationReview = try updatedSession.recommendationCandidates()
        .filter { !linkedCandidateIDs.contains($0.id) }
        .map(RecommendationCandidateDraft.init(candidate:))
      let summary = [
        merge.addedCandidates.isEmpty ? nil : "\(merge.addedCandidates.count) new",
        merge.updatedCandidates.isEmpty ? nil : "\(merge.updatedCandidates.count) updated",
        merge.unrankedCandidates.isEmpty ? nil : "\(merge.unrankedCandidates.count) no longer ranked",
      ].compactMap { $0 }.joined(separator: " · ")
      warnings.insert(summary.isEmpty ? "Nothing new." : summary, at: 0)
      recommendationHandoffPaste.warning = warnings.joined(separator: "\n\n")
      recommendationHandoffPaste.note = decoded.note
      recommendationHandoffPaste.noteSaved = false
    } catch {
      recommendationHandoffPaste.warning = "This clipboard content could not be imported: \(error.localizedDescription)"
    }
  }

  func saveRecommendationHandoffNote() {
    guard let note = recommendationHandoffPaste.note, !recommendationHandoffPaste.noteSaved else { return }
    do {
      let now = date.now
      _ = try database.write { db in
        try TripDocument.add(
          tripID: tripID,
          title: "Chat notes — \(now.formatted(date: .abbreviated, time: .omitted))",
          body: note,
          origin: .pasted,
          now: now,
          in: db
        )
      }
      recommendationHandoffPaste.noteSaved = true
    } catch {
      recommendationHandoffError = error.localizedDescription
    }
  }

  func clearRecommendationHandoffNote() {
    recommendationHandoffPaste.note = nil
    recommendationHandoffPaste.noteSaved = false
  }

  var seedPlanContextSnapshot: SeedPlanContext? {
    guard let trip else { return nil }
    return SeedPlanContext(
      trip: trip,
      tripIdeas: allTripIdeas.filter { $0.tripID == tripID },
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      stays: allTripStays.filter { $0.tripID == tripID },
      tripRegions: tripRegions,
      partyRegions: regions.filter { $0.travelPartyID == trip.travelPartyID },
      poolIdeas: ideas
    )
  }

  func commitRecommendationCandidate(_ candidate: RecommendationCandidateDraft, from session: HandoffSession) {
    guard candidate.canCommit else { return }
    withErrorReporting {
      var updatedSession = handoffSessionStore.session(session.id) ?? session
      let now = date.now
      updatedSession = try database.write { db in
        var updated = updatedSession
        try RecommendationSetImport.commit(candidate: candidate.candidate, into: tripID, session: &updated, now: now, in: db)
        return updated
      }
      try handoffSessionStore.save(updatedSession)
      recommendationReview.removeAll { $0.id == candidate.id }
    }
  }

  var mostRecentRecommendationWorkspaceSession: HandoffSession? {
    handoffSessionStore.sessions()
      .filter {
        $0.sourceID == tripID
          && ($0.taskType == RecommendationHandoffTask.candidatePlaces || $0.taskType == RecommendationHandoffTask.seedTrip)
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

  func recommendationPlaceSelected(stopID: TripIdea.ID, place: Place) {
    let result = withErrorReporting {
      try database.write { db -> (collision: ResolveReconcile.Collision?, confirmed: Bool) in
        guard let resolution = try GalavantSchema.RecommendationResolution.confirm(
          candidateStopID: stopID,
          capture: place.ideaCapture(),
          in: db
        ) else { return (nil, false) }
        if let collision = resolution.collision {
          try collision.action.apply(in: db)
        }
        return (resolution.collision, true)
      }
    }
    guard let result, result.confirmed else { return }
    if result.collision != nil {
      recommendationResolveNotice = "Already on this trip — updated Chat's notes."
    } else {
      destination = nil
    }
  }
}
