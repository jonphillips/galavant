import Dependencies
import Foundation
import GalavantAI
import GalavantPlaces
import GalavantSchema
import SQLiteData

struct RecommendationWorkspaceCandidate: Identifiable {
  let candidate: TripCandidate
  let tripIdea: TripIdea
  let idea: Idea?

  var id: TripIdea.ID { tripIdea.id }
  var title: String { tripIdea.inlineTitle ?? candidate.suggestedTitle }
  var isResolved: Bool { tripIdea.ideaID != nil }
  var isAwaitingResolutionOnItinerary: Bool { tripIdea.status == .scheduled && !isResolved }
}

struct RecommendationWorkspaceMapMarker: Identifiable {
  let id: UUID
  let title: String
  let latitude: Double
  let longitude: Double
  let state: CandidateMapMarkerState
}

struct RecommendationWorkspaceMapPlace: Identifiable {
  let id: UUID
  let title: String
  let latitude: Double
  let longitude: Double
}

struct RecommendationWorkspaceMapViewport: Equatable {
  let centerLatitude: Double
  let centerLongitude: Double
  let latitudeDelta: Double
  let longitudeDelta: Double
}

struct RecommendationBrowserLoadRequest: Hashable {
  let candidateID: TripIdea.ID
  let title: String
  let target: BrowserTargetDerivation.Target
  let ideaID: Idea.ID?
}

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
  @ObservationIgnored @FetchAll(TripIdea.all) private var allTripIdeas
  @ObservationIgnored @FetchAll(Idea.all) private var ideas
  @ObservationIgnored @FetchAll(TripStay.all) private var allTripStays
  @ObservationIgnored @FetchAll(TripRegion.all) private var allTripRegions
  @ObservationIgnored @FetchAll(MapRegion.all) private var regions

  let tripID: Trip.ID
  let sessionID: HandoffSession.ID
  var activeCandidateID: TripIdea.ID?
  var choiceCandidateIDs: Set<TripIdea.ID> = []
  var resolveResults: [Place] = []
  var pendingReconcile: ResolveReconcile.Collision?
  private var handoffCandidates: [TripCandidate] = []
  private var candidateLinks: [HandoffCandidateLink] = []
  private(set) var hasLoadedCandidateSet = false

  init(tripID: Trip.ID, sessionID: HandoffSession.ID) {
    self.tripID = tripID
    self.sessionID = sessionID
  }

  var candidates: [RecommendationWorkspaceCandidate] {
    let candidateByID = Dictionary(uniqueKeysWithValues: handoffCandidates.map { ($0.id, $0) })
    let tripIdeasByID = Dictionary(uniqueKeysWithValues: allTripIdeas.map { ($0.id, $0) })
    let ideasByID = Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0) })
    return candidateLinks.compactMap { link in
      guard
        let stopID = link.tripIdeaID,
        let candidate = candidateByID[link.candidateID],
        let tripIdea = tripIdeasByID[stopID],
        tripIdea.tripID == tripID,
        tripIdea.status == .considering || (tripIdea.status == .scheduled && tripIdea.ideaID == nil)
      else { return nil }
      return RecommendationWorkspaceCandidate(
        candidate: candidate,
        tripIdea: tripIdea,
        idea: tripIdea.ideaID.flatMap { ideasByID[$0] }
      )
    }
  }

  var activeCandidate: RecommendationWorkspaceCandidate? {
    guard let activeID = effectiveActiveCandidateID else { return nil }
    return candidates.first { $0.id == activeID }
  }

  var browserLoadRequest: RecommendationBrowserLoadRequest? {
    guard let activeCandidate else { return nil }
    let officialURL = activeCandidate.idea.flatMap { idea -> URL? in
      let text = idea.url.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : URL(string: text)
    }
    let resolution: BrowserTargetDerivation.Resolution = activeCandidate.isResolved
      ? .resolved(officialURL: officialURL)
      : .unresolved
    let target = BrowserTargetDerivation.target(for: activeCandidate.candidate, resolution: resolution)
    guard target != .unavailable else { return nil }
    return RecommendationBrowserLoadRequest(
      candidateID: activeCandidate.id,
      title: activeCandidate.title,
      target: target,
      ideaID: activeCandidate.tripIdea.ideaID
    )
  }

  var effectiveActiveCandidateID: TripIdea.ID? {
    CandidateSetTraversal(candidates: candidates.map(\.tripIdea))
      .active(preferredID: activeCandidateID)
  }

  var tripRegions: [MapRegion] {
    let regionIDs = Set(allTripRegions.filter { $0.tripID == tripID }.map(\.regionID))
    return regions.filter { regionIDs.contains($0.id) }
  }

  var itineraryMarkers: [RecommendationWorkspaceMapPlace] {
    let ideasByID = Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0) })
    let stopMarkers = allTripIdeas.compactMap { tripIdea -> RecommendationWorkspaceMapPlace? in
      guard
        tripIdea.tripID == tripID,
        tripIdea.status == .scheduled,
        let idea = tripIdea.ideaID.flatMap({ ideasByID[$0] }),
        let latitude = idea.latitude,
        let longitude = idea.longitude
      else { return nil }
      return RecommendationWorkspaceMapPlace(
        id: tripIdea.id,
        title: idea.name,
        latitude: latitude,
        longitude: longitude
      )
    }
    let stayMarkers = allTripStays.compactMap { stay -> RecommendationWorkspaceMapPlace? in
      guard
        stay.tripID == tripID,
        let idea = stay.ideaID.flatMap({ ideasByID[$0] }),
        let latitude = idea.latitude,
        let longitude = idea.longitude
      else { return nil }
      return RecommendationWorkspaceMapPlace(
        id: stay.id,
        title: idea.name,
        latitude: latitude,
        longitude: longitude
      )
    }
    return stopMarkers + stayMarkers
  }

  var candidateMarkers: [RecommendationWorkspaceMapMarker] {
    guard let effectiveActiveCandidateID else { return [] }
    return candidates.compactMap { candidate in
      let coordinate = candidate.idea.flatMap { idea -> (Double, Double)? in
        guard let latitude = idea.latitude, let longitude = idea.longitude else { return nil }
        return (latitude, longitude)
      } ?? fuzzyCoordinate(for: candidate.candidate)
      guard let coordinate else { return nil }
      return RecommendationWorkspaceMapMarker(
        id: candidate.id,
        title: candidate.title,
        latitude: coordinate.0,
        longitude: coordinate.1,
        state: CandidateMapMarkerState.state(for: candidate.tripIdea, activeID: effectiveActiveCandidateID)
      )
    }
  }

  var mapViewport: RecommendationWorkspaceMapViewport? {
    let coordinates = itineraryMarkers.map { ($0.latitude, $0.longitude) }
      + candidateMarkers.map { ($0.latitude, $0.longitude) }
      + resolveResults.map { ($0.latitude, $0.longitude) }
    guard
      let minimumLatitude = coordinates.map(\.0).min(),
      let maximumLatitude = coordinates.map(\.0).max(),
      let minimumLongitude = coordinates.map(\.1).min(),
      let maximumLongitude = coordinates.map(\.1).max()
    else { return nil }
    return RecommendationWorkspaceMapViewport(
      centerLatitude: (minimumLatitude + maximumLatitude) / 2,
      centerLongitude: (minimumLongitude + maximumLongitude) / 2,
      latitudeDelta: max((maximumLatitude - minimumLatitude) * 1.35, 0.08),
      longitudeDelta: max((maximumLongitude - minimumLongitude) * 1.35, 0.08)
    )
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

  private func fuzzyCoordinate(for candidate: TripCandidate) -> (Double, Double)? {
    guard let locality = candidate.locality?.lowercased() else { return nil }
    guard let region = tripRegions.first(where: {
      let name = $0.name.lowercased()
      return name.contains(locality) || locality.contains(name)
    }) else {
      return nil
    }
    return (region.centerLatitude, region.centerLongitude)
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

  private func nextCandidateAfterProcessing(_ candidateID: TripIdea.ID) -> TripIdea.ID? {
    CandidateSetTraversal(candidates: candidates.map(\.tripIdea))
      .activeAfterProcessing(candidateID)
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
