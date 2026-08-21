import GalavantSchema

/// The recommendation workspace's read-only view state. Every accessor here is a
/// thin delegation to `RecommendationWorkspaceProjection`, the pure join/derivation
/// core in GalavantSchema — the model stays an I/O shell, and the joins are tested
/// as value types (house style).
extension RecommendationWorkspaceModel {
  var projection: RecommendationWorkspaceProjection {
    RecommendationWorkspaceProjection(
      tripID: tripID,
      handoffCandidates: handoffCandidates,
      candidateLinks: candidateLinks,
      tripIdeas: allTripIdeas,
      ideas: ideas,
      stays: allTripStays,
      tripRegionLinks: allTripRegions,
      mapRegions: regions,
      trips: trips,
      preferredActiveCandidateID: activeCandidateID,
      resolveResultCoordinates: resolveResults.map {
        RecommendationWorkspaceProjection.Coordinate(latitude: $0.latitude, longitude: $0.longitude)
      }
    )
  }

  var candidates: [RecommendationWorkspaceCandidate] { projection.candidates }

  var effectiveActiveCandidateID: TripIdea.ID? { projection.effectiveActiveCandidateID }

  var activeCandidate: RecommendationWorkspaceCandidate? { projection.activeCandidate }

  var browserLoadRequest: RecommendationBrowserLoadRequest? { projection.browserLoadRequest }

  var activeCandidateLocation: (latitude: Double, longitude: Double)? {
    projection.activeCandidateLocation
  }

  var tripRegions: [MapRegion] { projection.tripRegions }

  /// Where the map's "search this map" field should look for the focused candidate:
  /// a box around its locality when the LLM gave one, else the trip's regions. Keeps
  /// the type-a-name search as geographically honest as the Connect button, using
  /// geography we already hold (no extra model call).
  var candidateSearchRegions: [MapRegion] {
    RecommendationCandidateSearch.searchRegions(
      localityLatitude: activeCandidateLocation?.latitude,
      localityLongitude: activeCandidateLocation?.longitude,
      tripRegions: tripRegions
    )
  }

  var tripDays: [RecommendationWorkspaceDay] { projection.tripDays }

  var itineraryMarkers: [RecommendationWorkspaceMapPlace] { projection.itineraryMarkers }

  var candidateMarkers: [RecommendationWorkspaceMapMarker] { projection.candidateMarkers }

  var mapViewport: RecommendationWorkspaceMapViewport? { projection.mapViewport }

  func nextCandidateAfterProcessing(_ candidateID: TripIdea.ID) -> TripIdea.ID? {
    projection.activeCandidateAfterProcessing(candidateID)
  }
}
