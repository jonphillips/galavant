import Foundation
import GalavantPlaces
import GalavantSchema

extension CalendarReconciliationModel {
  private struct PromotionPayload: Sendable {
    let id: Idea.ID
    let name: String
    let description: String
    let notes: String
    let kind: IdeaKind?
    let regionName: String?
    let address: String?
    let phone: String?
    let latitude: Double?
    let longitude: Double?
    let url: String
    let visited: Bool
    let openingHours: String?
    let hoursProvenance: FactProvenance?
    let hoursVerifiedAt: Date?
    let structuredHours: String?
    let enrichedAt: Date?
    let mapItemIdentifier: String?
    let travelPartyID: TravelParty.ID?

    init(draft: Idea.Draft) {
      id = draft.id ?? UUID()
      name = draft.name
      description = draft.description
      notes = draft.notes
      kind = draft.kind
      regionName = draft.regionName
      address = draft.address
      phone = draft.phone
      latitude = draft.latitude
      longitude = draft.longitude
      url = draft.url
      visited = draft.visited
      openingHours = draft.openingHours
      hoursProvenance = draft.hoursProvenance
      hoursVerifiedAt = draft.hoursVerifiedAt
      structuredHours = draft.structuredHours
      enrichedAt = draft.enrichedAt
      mapItemIdentifier = draft.mapItemIdentifier
      travelPartyID = draft.travelPartyID
    }

    var draft: Idea.Draft {
      Idea.Draft(
        Idea(
          id: id,
          name: name,
          description: description,
          notes: notes,
          kind: kind,
          regionName: regionName,
          address: address,
          phone: phone,
          latitude: latitude,
          longitude: longitude,
          url: url,
          visited: visited,
          openingHours: openingHours,
          hoursProvenance: hoursProvenance,
          hoursVerifiedAt: hoursVerifiedAt,
          structuredHours: structuredHours,
          enrichedAt: enrichedAt,
          mapItemIdentifier: mapItemIdentifier,
          travelPartyID: travelPartyID))
    }
  }

  private enum PromotionError: LocalizedError {
    case missingPlaceIdentity
    case missingCalendar
    case missingCandidate
    case missingStop

    var errorDescription: String? {
      switch self {
      case .missingPlaceIdentity:
        "Choose a named Apple Maps place before promoting this event."
      case .missingCalendar:
        "Choose the shared Calendar before promoting this event."
      case .missingCandidate:
        "Galavant could not find the Calendar event behind this constraint. Refresh and try again."
      case .missingStop:
        "Galavant could not place the selected place on this trip."
      }
    }
  }

  /// Assigns a real Maps place to a Calendar constraint, then sends the resulting
  /// idea-backed day stop through the established manual-link path. Calendar owns
  /// the event's time; `link` is the only operation that applies it.
  func promote(
    constraint: CalendarTripConstraint,
    place: Place,
    trip: Trip,
    plan: TripPlan
  ) async {
    do {
      guard place.mapItemIdentifier != nil else { throw PromotionError.missingPlaceIdentity }
      guard constraint.tripID == trip.id else { throw PromotionError.missingCandidate }
      guard let selectedCalendarID else { throw PromotionError.missingCalendar }

      if CalendarReconciliation.candidate(for: constraint, in: candidates) == nil {
        await refresh(trip: trip, plan: plan)
      }
      guard let candidate = CalendarReconciliation.candidate(for: constraint, in: candidates),
        candidate.input.event.isEligibleForSharedReconciliation,
        candidate.input.event.hasStableLocalIdentity
      else { throw PromotionError.missingCandidate }

      let draft = PromotionPayload(draft: await MapPlaceCapture().draft(for: place))
      let stopID = try await database.write { db in
        let ideaID = try Idea.save(draft.draft, tagNames: [], in: db)
        let stop = try TripIdea.pull(ideaID: ideaID, into: trip.id, in: db)
        try TripIdea.schedule(.day(constraint.dayNumber), stopID: stop.id, in: db)
        return stop.id
      }
      let updatedPlan = try await planAfterPromoting(
        stopID: stopID, tripID: trip.id, base: plan)
      guard let stop = updatedPlan.itinerary.flatMap(\.stops).first(where: { $0.id == stopID })
      else {
        throw PromotionError.missingStop
      }

      await link(
        candidate,
        to: stop,
        trip: trip,
        plan: updatedPlan,
        selectedCalendarID: selectedCalendarID)
    } catch {
      state = .failure(error.localizedDescription)
    }
  }

  private func planAfterPromoting(
    stopID: TripIdea.ID,
    tripID: Trip.ID,
    base: TripPlan
  ) async throws -> TripPlan {
    try await database.read { db in
      var plan = base
      plan.entries = try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db)
      guard let stop = plan.entries.first(where: { $0.id == stopID }),
        let ideaID = stop.ideaID,
        let idea = try Idea.find(ideaID).fetchOne(db)
      else { throw PromotionError.missingStop }
      plan.ideasByID[idea.id] = idea
      return plan
    }
  }
}
