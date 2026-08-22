import Dependencies
import Foundation
import GalavantAI
import GalavantImaging
import GalavantPlaces
import GalavantSchema
import SQLiteData

private struct DismissedRecommendationCandidate {
  let tripIdea: TripIdea
  let alternativeMemberIDs: [TripIdea.ID]
  let activeAlternativeID: TripIdea.ID?
}

struct RecommendationWorkspaceStatus: Equatable {
  enum Kind: Equatable {
    case success
    case failure
  }

  let candidateID: TripIdea.ID
  let message: String
  let kind: Kind
}

@MainActor
@Observable
final class RecommendationWorkspaceModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.uuid) private var uuid
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
  private(set) var candidateAnchors: [TripIdea.ID: RecommendationWorkspaceProjection.Coordinate] = [:]
  /// Ideas this session minted while resolving (as opposed to reusing a pool idea via
  /// dedup). Disconnect deletes only these, and only if nothing else references them,
  /// so a wrong tap leaves no throwaway idea behind. Session-only by design — after a
  /// relaunch we conservatively keep the idea rather than guess it was disposable.
  private var mintedIdeaIDs: Set<Idea.ID> = []
  var workspaceStatus: RecommendationWorkspaceStatus?
  private(set) var hasLoadedCandidateSet = false

  init(tripID: Trip.ID, sessionID: HandoffSession.ID) {
    self.tripID = tripID
    self.sessionID = sessionID
  }

  func task() async {
    loadCandidateSet()
    activeCandidateID = effectiveActiveCandidateID
    await loadCandidateAnchors()
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
    let didSave = withErrorReporting {
      try database.write { db -> Bool in
        guard let stored = try TripIdea.find(candidate.id).fetchOne(db) else { return false }
        try TripIdea.setStatus(.shortlisted, stopID: candidate.id, in: db)
        if let ideaID = stored.ideaID {
          guard try Idea.find(ideaID).fetchOne(db) != nil else {
            return false
          }
        }
        return true
      }
    }
    guard didSave == true else {
      workspaceStatus = RecommendationWorkspaceStatus(
        candidateID: candidate.id,
        message: "\(candidate.title) was shortlisted, but its Idea record could not be verified.",
        kind: .failure
      )
      return
    }
    workspaceStatus = RecommendationWorkspaceStatus(
      candidateID: candidate.id,
      message: candidate.isResolved
        ? "\(candidate.title) is now on the shortlist and in Ideas."
        : "\(candidate.title) is now on the trip shortlist.",
      kind: .success
    )
    choiceCandidateIDs.remove(candidate.id)
    activeCandidateID = nextCandidateID
    resolveResults = []
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

  /// Undo a wrong pin: unlink the resolved place so the candidate is unresolved
  /// again and re-resolvable on the map. Best-effort re-geocodes a display anchor so
  /// the candidate keeps a rough pin instead of vanishing. The detached Idea stays
  /// in the pool (never a write-back to the Idea, mirroring the anchor's rules).
  func disconnectButtonTapped(_ candidate: RecommendationWorkspaceCandidate) {
    guard candidate.isResolved else { return }
    let detachedIdeaID = candidate.idea?.id
    let mintedHere = detachedIdeaID.map(mintedIdeaIDs.contains) ?? false
    withErrorReporting {
      try database.write { db in
        try TripIdea.detachResolvedIdea(
          from: candidate.id,
          deletingOrphanedIdea: mintedHere,
          in: db
        )
      }
      if let detachedIdeaID { mintedIdeaIDs.remove(detachedIdeaID) }
      activeCandidateID = candidate.id
      resolveResults = []
      candidateAnchors[candidate.id] = nil
      workspaceStatus = RecommendationWorkspaceStatus(
        candidateID: candidate.id,
        message: "\(candidate.title) is unresolved again — pick its place on the map.",
        kind: .success
      )
    }
    Task { await loadCandidateAnchors() }
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

  /// Store an image dragged from the regular-width research browser on the focused
  /// candidate's resolved idea. Unresolved candidates deliberately have nowhere to
  /// attach an image: ImageAsset's single FK rides the shared graph through Idea.
  func attachDroppedImage(_ data: Data, sourceURL: String?) async {
    guard let ideaID = activeCandidate?.idea?.id else { return }
    let candidateID = activeCandidate?.id ?? ideaID
    let candidateTitle = activeCandidate?.title ?? "candidate"
    workspaceStatus = nil

    // Image decoding/resizing is pure CPU work. Keep it off the main actor while the
    // model remains the owner of the subsequent database write and UI status.
    let processed = await Task.detached(priority: .userInitiated) {
      ImageProcessing.process(data)
    }.value
    guard let processed else {
      workspaceStatus = RecommendationWorkspaceStatus(
        candidateID: candidateID,
        message: "That drop was not a readable image.",
        kind: .failure
      )
      return
    }

    let imageID = uuid()
    workspaceStatus = RecommendationWorkspaceStatus(
      candidateID: candidateID,
      message: "Couldn't save the photo to \(candidateTitle).",
      kind: .failure
    )
    await withErrorReporting {
      try await database.write { [ideaID, imageID, processed, sourceURL] db in
        try ImageAsset.store(
          ideaID: ideaID,
          display: processed.display,
          thumbnail: processed.thumbnail,
          sourceURL: sourceURL,
          id: imageID,
          in: db
        )
      }
      workspaceStatus = RecommendationWorkspaceStatus(
        candidateID: candidateID,
        message: "Photo added to \(candidateTitle).",
        kind: .success
      )
    }
  }

  func imageDropProviderFailed() {
    guard let candidate = activeCandidate, candidate.idea != nil else { return }
    workspaceStatus = RecommendationWorkspaceStatus(
      candidateID: candidate.id,
      message: "Couldn't read that drop as an image.",
      kind: .failure
    )
  }

  func resolveResultTapped(_ place: Place) {
    guard let activeCandidate else { return }
    withErrorReporting {
      pendingReconcile = try database.write { db in
        guard let resolution = try RecommendationResolution.confirm(
          candidateStopID: activeCandidate.id,
          place: place,
          in: db
        ) else { return nil }
        if resolution.isNew { mintedIdeaIDs.insert(resolution.ideaID) }
        let tripIdeas = try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db)
        return ResolveReconcile(
          tripIdeas: tripIdeas,
          resolvedIdeaID: resolution.ideaID,
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

  /// Geocode unresolved candidates for display only. These coordinates are session
  /// state: they never become an Idea coordinate and never resolve a candidate.
  func loadCandidateAnchors() async {
    for candidate in candidates where !candidate.isResolved && candidateAnchors[candidate.id] == nil {
      guard !Task.isCancelled else { return }
      let matches = await placeMatcher.matches(for: candidate.candidate, in: tripRegions)
      guard !Task.isCancelled else { return }
      guard
        candidates.first(where: { $0.id == candidate.id })?.isResolved == false,
        candidateAnchors[candidate.id] == nil,
        let firstMatch = matches.first
      else { continue }
      candidateAnchors[candidate.id] = RecommendationWorkspaceProjection.Coordinate(
        latitude: firstMatch.latitude,
        longitude: firstMatch.longitude
      )
    }
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
