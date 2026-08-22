import Foundation
import GalavantSchema
import LLMHandoffKit
import Testing

@Suite struct RecommendationWorkspaceProjectionTests {
  private let tripID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!

  /// Builds a projection over a candidate set. Each tuple is one linked candidate:
  /// its handoff `TripCandidate`, the committed `TripIdea` it links to, and the pool
  /// `Idea` it resolves to (when any). Extra unlinked ideas/stays/regions/trips can be
  /// supplied to exercise the joins.
  private func projection(
    candidates: [(candidate: TripCandidate, tripIdea: TripIdea, idea: Idea?)],
    extraTripIdeas: [TripIdea] = [],
    extraIdeas: [Idea] = [],
    stays: [TripStay] = [],
    tripRegionLinks: [TripRegion] = [],
    mapRegions: [MapRegion] = [],
    trips: [Trip] = [],
    preferredActiveCandidateID: TripIdea.ID? = nil,
    resolveResultCoordinates: [RecommendationWorkspaceProjection.Coordinate] = [],
    candidateAnchors: [TripIdea.ID: RecommendationWorkspaceProjection.Coordinate] = [:]
  ) -> RecommendationWorkspaceProjection {
    RecommendationWorkspaceProjection(
      tripID: tripID,
      handoffCandidates: candidates.map(\.candidate),
      candidateLinks: candidates.map {
        HandoffCandidateLink(candidateID: $0.candidate.id, tripIdeaID: $0.tripIdea.id)
      },
      tripIdeas: candidates.map(\.tripIdea) + extraTripIdeas,
      ideas: candidates.compactMap(\.idea) + extraIdeas,
      stays: stays,
      tripRegionLinks: tripRegionLinks,
      mapRegions: mapRegions,
      trips: trips,
      preferredActiveCandidateID: preferredActiveCandidateID,
      resolveResultCoordinates: resolveResultCoordinates,
      candidateAnchors: candidateAnchors
    )
  }

  private func candidate(
    _ candidateID: UUID = UUID(),
    stopID: UUID,
    rank: Int = 0,
    status: TripIdeaStatus = .considering,
    ideaID: UUID? = nil,
    name: String? = "Candidate",
    searchHint: String? = nil,
    locality: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    url: String = ""
  ) -> (candidate: TripCandidate, tripIdea: TripIdea, idea: Idea?) {
    let candidate = TripCandidate(
      id: candidateID, name: name, locality: locality, searchHint: searchHint)
    let tripIdea = TripIdea(
      id: stopID, tripID: tripID, ideaID: ideaID,
      inlineTitle: name, status: status, shortlistRank: rank)
    let idea = ideaID.map {
      Idea(id: $0, name: name ?? "", latitude: latitude, longitude: longitude, url: url)
    }
    return (candidate, tripIdea, idea)
  }

  @Test func candidatesKeepsOnlyLinkedRowsForThisTripAndReviewableStatus() {
    let considering = UUID()
    let scheduledUnresolved = UUID()
    let scheduledResolved = UUID()
    let ideaID = UUID()
    let otherTripStop = UUID()

    let otherTripIdea = TripIdea(
      id: otherTripStop, tripID: UUID(), ideaID: nil, status: .considering)
    let projection = projection(
      candidates: [
        candidate(stopID: considering, status: .considering),
        candidate(stopID: scheduledUnresolved, status: .scheduled),
        candidate(stopID: scheduledResolved, status: .scheduled, ideaID: ideaID),
      ],
      extraTripIdeas: [otherTripIdea]
    )

    let ids = Set(projection.candidates.map(\.id))
    // Considering and unresolved-scheduled rows are reviewable; a resolved-scheduled
    // row has left the workspace (it's a real stop now), and other trips never appear.
    #expect(ids == [considering, scheduledUnresolved])
    #expect(!ids.contains(otherTripStop))
  }

  @Test func activeCandidateFollowsCanonicalOrderThenPreferredSelection() {
    let first = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let second = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

    let base = projection(candidates: [
      candidate(stopID: second, rank: 2),
      candidate(stopID: first, rank: 1),
    ])
    #expect(base.effectiveActiveCandidateID == first)
    #expect(base.activeCandidate?.id == first)

    let preferred = projection(
      candidates: [
        candidate(stopID: second, rank: 2),
        candidate(stopID: first, rank: 1),
      ],
      preferredActiveCandidateID: second
    )
    #expect(preferred.effectiveActiveCandidateID == second)
    #expect(preferred.activeCandidateAfterProcessing(second) == first)
  }

  @Test func browserRequestPrefersOfficialSiteThenHintThenTitleFallback() {
    let resolvedStop = UUID()
    let resolved = projection(
      candidates: [
        candidate(
          stopID: resolvedStop, status: .considering, ideaID: UUID(),
          name: "Kloster Neustift", url: "https://www.kloster-neustift.it"),
      ],
      preferredActiveCandidateID: resolvedStop
    )
    #expect(
      resolved.browserLoadRequest?.target
        == .website(URL(string: "https://www.kloster-neustift.it")!))

    let hintStop = UUID()
    let hinted = projection(
      candidates: [
        candidate(stopID: hintStop, name: "Neustift Abbey", searchHint: "Neustift Abbey South Tyrol"),
      ],
      preferredActiveCandidateID: hintStop
    )
    #expect(hinted.browserLoadRequest?.target == .search(query: "Neustift Abbey South Tyrol"))

    // No hint on an unresolved candidate: fall back to searching its title rather
    // than dead-ending the browser.
    let bareStop = UUID()
    let bare = projection(
      candidates: [candidate(stopID: bareStop, name: "Just A Name", searchHint: nil)],
      preferredActiveCandidateID: bareStop
    )
    #expect(bare.browserLoadRequest?.target == .search(query: "Just A Name"))
  }

  @Test func itineraryMarkersCoverScheduledResolvedStopsAndStays() {
    let scheduledStopID = UUID()
    let scheduledIdeaID = UUID()
    let consideringStopID = UUID()
    let stayID = UUID()
    let stayIdeaID = UUID()

    let scheduledStop = TripIdea(
      id: scheduledStopID, tripID: tripID, ideaID: scheduledIdeaID, status: .scheduled)
    let consideringStop = TripIdea(
      id: consideringStopID, tripID: tripID, ideaID: UUID(), status: .considering)
    let stopIdea = Idea(id: scheduledIdeaID, name: "Museum", latitude: 46.5, longitude: 11.4)
    let stayIdea = Idea(id: stayIdeaID, name: "Hotel", latitude: 46.4, longitude: 11.3)
    let stay = TripStay(id: stayID, tripID: tripID, ideaID: stayIdeaID)

    let projection = projection(
      candidates: [],
      extraTripIdeas: [scheduledStop, consideringStop],
      extraIdeas: [stopIdea, stayIdea],
      stays: [stay]
    )

    let markerIDs = Set(projection.itineraryMarkers.map(\.id))
    // Only the scheduled, resolved, coordinate-bearing stop plus the stay are mapped;
    // a still-considering stop is not part of the committed itinerary.
    #expect(markerIDs == [scheduledStopID, stayID])
  }

  @Test func candidateMarkersPreferResolvedCoordinateThenAnchorAndOmitAnchorlessCandidates() {
    let resolvedStop = UUID()
    let anchoredStop = UUID()
    let anchorlessStop = UUID()

    let projection = projection(
      candidates: [
        candidate(
          stopID: resolvedStop, rank: 1, ideaID: UUID(),
          name: "Uffizi", latitude: 43.76, longitude: 11.25),
        candidate(stopID: anchoredStop, rank: 2, name: "Trattoria"),
        candidate(stopID: anchorlessStop, rank: 3, name: "Unlocated"),
      ],
      preferredActiveCandidateID: anchoredStop,
      candidateAnchors: [
        resolvedStop: .init(latitude: 40, longitude: 10),
        anchoredStop: .init(latitude: 43.78, longitude: 11.26),
      ]
    )

    let markers = Dictionary(uniqueKeysWithValues: projection.candidateMarkers.map { ($0.id, $0) })
    #expect(markers[resolvedStop]?.latitude == 43.76)
    #expect(markers[resolvedStop]?.state == .resolved(isActive: false))
    #expect(markers[anchoredStop]?.latitude == 43.78)
    #expect(markers[anchoredStop]?.state == .fuzzy(isActive: true))
    #expect(markers[anchorlessStop] == nil)
    #expect(projection.activeCandidateLocation?.latitude == 43.78)
    #expect(projection.activeCandidateLocation?.longitude == 11.26)
  }

  @Test func mapViewportFramesEveryPlottedCoordinate() {
    let stopID = UUID()
    let ideaID = UUID()
    let anchoredCandidateStopID = UUID()
    let stop = TripIdea(id: stopID, tripID: tripID, ideaID: ideaID, status: .scheduled)
    let idea = Idea(id: ideaID, name: "North", latitude: 47.0, longitude: 11.0)

    let projection = projection(
      candidates: [candidate(stopID: anchoredCandidateStopID, name: "South")],
      extraTripIdeas: [stop],
      extraIdeas: [idea],
      preferredActiveCandidateID: anchoredCandidateStopID,
      resolveResultCoordinates: [.init(latitude: 45.0, longitude: 13.0)],
      candidateAnchors: [anchoredCandidateStopID: .init(latitude: 48.0, longitude: 11.5)]
    )

    let viewport = projection.mapViewport
    #expect(viewport?.centerLatitude == 46.5)
    #expect(viewport?.centerLongitude == 12.0)
    // Span includes the in-memory candidate anchor and is padded by 1.35.
    #expect(viewport?.latitudeDelta == max(3.0 * 1.35, 0.08))
    #expect(viewport?.longitudeDelta == max(2.0 * 1.35, 0.08))
  }

  @Test func tripDaysAreDatedOnlyWhenTheTripHasAStartDate() {
    let start = DateComponents(
      calendar: .current, year: 2026, month: 6, day: 10).date!
    let datedTrip = Trip(id: tripID, name: "Dolomites", startDate: start, lengthInDays: 3)
    let dated = projection(candidates: [], trips: [datedTrip]).tripDays
    #expect(dated.map(\.number) == [1, 2, 3])
    #expect(dated.first?.date == start)
    #expect(dated.allSatisfy { $0.date != nil })

    let undatedTrip = Trip(id: tripID, name: "Someday", startDate: nil, lengthInDays: 2)
    let undated = projection(candidates: [], trips: [undatedTrip]).tripDays
    #expect(undated.map(\.number) == [1, 2])
    #expect(undated.allSatisfy { $0.date == nil })
  }

  @Test func tripRegionsResolveOnlyThisTripsLinkedRegions() {
    let mine = UUID()
    let other = UUID()
    let mineRegion = MapRegion(
      id: mine, name: "Mine", centerLatitude: 1, centerLongitude: 1,
      latitudeDelta: 0.1, longitudeDelta: 0.1)
    let otherRegion = MapRegion(
      id: other, name: "Other", centerLatitude: 2, centerLongitude: 2,
      latitudeDelta: 0.1, longitudeDelta: 0.1)

    let projection = projection(
      candidates: [],
      tripRegionLinks: [
        TripRegion(id: UUID(), tripID: tripID, regionID: mine),
        TripRegion(id: UUID(), tripID: UUID(), regionID: other),
      ],
      mapRegions: [mineRegion, otherRegion]
    )

    #expect(projection.tripRegions.map(\.id) == [mine])
  }
}
