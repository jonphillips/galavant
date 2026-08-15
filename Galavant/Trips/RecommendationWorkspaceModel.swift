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

/// One selectable day for the "Add to Day" placement menu: its number and, when the
/// trip is dated, its calendar date for a human label.
struct RecommendationWorkspaceDay: Identifiable {
  let number: Int
  let date: Date?
  var id: Int { number }
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
  @ObservationIgnored @FetchAll(Trip.all) private var trips

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
    let derived = BrowserTargetDerivation.target(for: activeCandidate.candidate, resolution: resolution)
    // A candidate with no search hint (e.g. a manually added one) derives no target.
    // Rather than dead-end the browser, fall back to searching its title so there's
    // always something to browse from.
    let target: BrowserTargetDerivation.Target
    if derived == .unavailable, !activeCandidate.isResolved {
      let title = activeCandidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
      target = title.isEmpty ? .unavailable : .search(query: title)
    } else {
      target = derived
    }
    guard target != .unavailable else { return nil }
    return RecommendationBrowserLoadRequest(
      candidateID: activeCandidate.id,
      title: activeCandidate.title,
      target: target,
      ideaID: activeCandidate.tripIdea.ideaID
    )
  }

  /// The focused candidate's map coordinate (resolved place, else its fuzzy locality),
  /// so the map can pan to keep the active pin in view when you switch candidates.
  var activeCandidateLocation: (latitude: Double, longitude: Double)? {
    guard let id = effectiveActiveCandidateID else { return nil }
    return candidateMarkers.first { $0.id == id }.map { ($0.latitude, $0.longitude) }
  }

  var effectiveActiveCandidateID: TripIdea.ID? {
    CandidateSetTraversal(candidates: candidates.map(\.tripIdea))
      .active(preferredID: activeCandidateID)
  }

  var tripRegions: [MapRegion] {
    let regionIDs = Set(allTripRegions.filter { $0.tripID == tripID }.map(\.regionID))
    return regions.filter { regionIDs.contains($0.id) }
  }

  private var trip: Trip? { trips.first { $0.id == tripID } }

  /// The trip's days for the "Add to Day" menu, dated when the trip has a start date.
  var tripDays: [RecommendationWorkspaceDay] {
    guard let trip else { return [] }
    let count = max(trip.lengthInDays, 1)
    let calendar = Calendar.current
    return (1...count).map { number in
      let date = trip.startDate.flatMap {
        calendar.date(byAdding: .day, value: number - 1, to: $0)
      }
      return RecommendationWorkspaceDay(number: number, date: date)
    }
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
