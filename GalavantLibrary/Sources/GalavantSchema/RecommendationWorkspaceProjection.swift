import Foundation
import LLMHandoffKit

public struct RecommendationWorkspaceCandidate: Identifiable {
  public let candidate: TripCandidate
  public let tripIdea: TripIdea
  public let idea: Idea?

  public init(candidate: TripCandidate, tripIdea: TripIdea, idea: Idea?) {
    self.candidate = candidate
    self.tripIdea = tripIdea
    self.idea = idea
  }

  public var id: TripIdea.ID { tripIdea.id }
  public var title: String { tripIdea.inlineTitle ?? candidate.suggestedTitle }
  public var isResolved: Bool { tripIdea.ideaID != nil }
  public var isAwaitingResolutionOnItinerary: Bool { tripIdea.status == .scheduled && !isResolved }
}

public struct RecommendationWorkspaceMapMarker: Identifiable {
  public let id: UUID
  public let title: String
  public let latitude: Double
  public let longitude: Double
  public let state: CandidateMapMarkerState

  public init(id: UUID, title: String, latitude: Double, longitude: Double, state: CandidateMapMarkerState) {
    self.id = id
    self.title = title
    self.latitude = latitude
    self.longitude = longitude
    self.state = state
  }
}

public struct RecommendationWorkspaceMapPlace: Identifiable {
  public let id: UUID
  public let title: String
  public let latitude: Double
  public let longitude: Double

  public init(id: UUID, title: String, latitude: Double, longitude: Double) {
    self.id = id
    self.title = title
    self.latitude = latitude
    self.longitude = longitude
  }
}

public struct RecommendationWorkspaceMapViewport: Equatable {
  public let centerLatitude: Double
  public let centerLongitude: Double
  public let latitudeDelta: Double
  public let longitudeDelta: Double

  public init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
    self.centerLatitude = centerLatitude
    self.centerLongitude = centerLongitude
    self.latitudeDelta = latitudeDelta
    self.longitudeDelta = longitudeDelta
  }
}

/// One selectable day for the "Add to Day" placement menu: its number and, when the
/// trip is dated, its calendar date for a human label.
public struct RecommendationWorkspaceDay: Identifiable {
  public let number: Int
  public let date: Date?
  public var id: Int { number }

  public init(number: Int, date: Date?) {
    self.number = number
    self.date = date
  }
}

public struct RecommendationBrowserLoadRequest: Hashable {
  public let candidateID: TripIdea.ID
  public let title: String
  public let target: BrowserTargetDerivation.Target
  public let ideaID: Idea.ID?

  public init(candidateID: TripIdea.ID, title: String, target: BrowserTargetDerivation.Target, ideaID: Idea.ID?) {
    self.candidateID = candidateID
    self.title = title
    self.target = target
    self.ideaID = ideaID
  }
}

/// The pure read model behind the recommendation workspace: it joins the handoff
/// candidate set against the trip's ideas, stays, and regions to derive the review
/// list, the map layers, the browser target, and candidate traversal. It owns no
/// I/O — the model feeds it fetched rows plus the current selection, and reads back
/// the derived view state. Keeping the joins here keeps `RecommendationWorkspaceModel`
/// a thin I/O shell (house style: pure read-model logic in the functional core).
public struct RecommendationWorkspaceProjection {
  public struct Coordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
      self.latitude = latitude
      self.longitude = longitude
    }
  }

  public let tripID: Trip.ID
  public let handoffCandidates: [TripCandidate]
  public let candidateLinks: [HandoffCandidateLink]
  public let tripIdeas: [TripIdea]
  public let ideas: [Idea]
  public let stays: [TripStay]
  public let tripRegionLinks: [TripRegion]
  public let mapRegions: [MapRegion]
  public let trips: [Trip]
  public let preferredActiveCandidateID: TripIdea.ID?
  public let resolveResultCoordinates: [Coordinate]

  public init(
    tripID: Trip.ID,
    handoffCandidates: [TripCandidate],
    candidateLinks: [HandoffCandidateLink],
    tripIdeas: [TripIdea],
    ideas: [Idea],
    stays: [TripStay],
    tripRegionLinks: [TripRegion],
    mapRegions: [MapRegion],
    trips: [Trip],
    preferredActiveCandidateID: TripIdea.ID?,
    resolveResultCoordinates: [Coordinate] = []
  ) {
    self.tripID = tripID
    self.handoffCandidates = handoffCandidates
    self.candidateLinks = candidateLinks
    self.tripIdeas = tripIdeas
    self.ideas = ideas
    self.stays = stays
    self.tripRegionLinks = tripRegionLinks
    self.mapRegions = mapRegions
    self.trips = trips
    self.preferredActiveCandidateID = preferredActiveCandidateID
    self.resolveResultCoordinates = resolveResultCoordinates
  }

  public var candidates: [RecommendationWorkspaceCandidate] {
    let candidateByID = Dictionary(uniqueKeysWithValues: handoffCandidates.map { ($0.id, $0) })
    let tripIdeasByID = Dictionary(uniqueKeysWithValues: tripIdeas.map { ($0.id, $0) })
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

  public var effectiveActiveCandidateID: TripIdea.ID? {
    CandidateSetTraversal(candidates: candidates.map(\.tripIdea))
      .active(preferredID: preferredActiveCandidateID)
  }

  public var activeCandidate: RecommendationWorkspaceCandidate? {
    guard let activeID = effectiveActiveCandidateID else { return nil }
    return candidates.first { $0.id == activeID }
  }

  /// The next candidate to focus once `candidateID` leaves the set (saved, dismissed,
  /// scheduled): the canonical successor, or `nil` once the set is empty.
  public func activeCandidateAfterProcessing(_ candidateID: TripIdea.ID) -> TripIdea.ID? {
    CandidateSetTraversal(candidates: candidates.map(\.tripIdea))
      .activeAfterProcessing(candidateID)
  }

  public var browserLoadRequest: RecommendationBrowserLoadRequest? {
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
  public var activeCandidateLocation: (latitude: Double, longitude: Double)? {
    guard let id = effectiveActiveCandidateID else { return nil }
    return candidateMarkers.first { $0.id == id }.map { ($0.latitude, $0.longitude) }
  }

  public var tripRegions: [MapRegion] {
    let regionIDs = Set(tripRegionLinks.filter { $0.tripID == tripID }.map(\.regionID))
    return mapRegions.filter { regionIDs.contains($0.id) }
  }

  private var trip: Trip? { trips.first { $0.id == tripID } }

  /// The trip's days for the "Add to Day" menu, dated when the trip has a start date.
  public var tripDays: [RecommendationWorkspaceDay] {
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

  public var itineraryMarkers: [RecommendationWorkspaceMapPlace] {
    let ideasByID = Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0) })
    let stopMarkers = tripIdeas.compactMap { tripIdea -> RecommendationWorkspaceMapPlace? in
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
    let stayMarkers = stays.compactMap { stay -> RecommendationWorkspaceMapPlace? in
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

  public var candidateMarkers: [RecommendationWorkspaceMapMarker] {
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

  public var mapViewport: RecommendationWorkspaceMapViewport? {
    let coordinates = itineraryMarkers.map { ($0.latitude, $0.longitude) }
      + candidateMarkers.map { ($0.latitude, $0.longitude) }
      + resolveResultCoordinates.map { ($0.latitude, $0.longitude) }
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
}
