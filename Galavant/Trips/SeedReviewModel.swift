import Dependencies
import Foundation
import GalavantAI
import GalavantPlaces
import GalavantSchema
import SQLiteData

@MainActor
@Observable
final class SeedReviewModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.handoffSessionStore) private var handoffSessionStore
  @ObservationIgnored @Dependency(\.date) private var date
  @ObservationIgnored @Dependency(\.seedPlaceSearch) private var seedPlaceSearch

  var plan: SeedPlan?
  var error: String?
  var importSummary: String?
  var mapResults: [UUID: [Place]] = [:]
  var selectedMapPlaces: [UUID: Place] = [:]
  var preselectedMapPlaces: [UUID: UUID] = [:]
  var matchingRows: Set<UUID> = []
  var matchingFinished = false
  private var poolIdeas: [Idea] = []
  private var tripIdeas: [TripIdea] = []
  private var tripStays: [TripStay] = []
  private var tripRegions: [MapRegion] = []
  private var matchingTask: Task<Void, Never>?

  func paste(_ strings: [String], for session: HandoffSession, context: SeedPlanContext?) {
    guard let pasted = strings.first, let context else { return }
    do {
      var warnings: [String] = []
      let bodyText: String
      if let routed = try? HandoffRouting.route(pasted) {
        bodyText = routed.text
        if routed.sessionID != session.id {
          warnings.append("This result was tagged for a different handoff — added it to this trip anyway.")
        }
      } else {
        bodyText = pasted
        warnings.append("This result had no Galavant handoff token — added it to this trip anyway.")
      }
      let contract = try RecommendationHandoffContract.marker.strippingMarker(from: bodyText)
      if let warning = contract.warning { warnings.append(warning) }
      var decoded = try SeedReturn.decode(contract.text)
      decoded.warnings.insert(contentsOf: warnings, at: 0)
      plan = SeedPlan.make(from: decoded, trip: context.trip, context: context)
      poolIdeas = context.poolIdeas
      tripIdeas = context.tripIdeas
      tripStays = context.stays
      tripRegions = context.tripRegions
      mapResults = [:]
      selectedMapPlaces = [:]
      preselectedMapPlaces = [:]
      matchingRows = []
      matchingFinished = false
      error = nil
      matchingTask?.cancel()
      matchingTask = Task { await matchRows() }
    } catch {
      self.error = error.localizedDescription
    }
  }

  @discardableResult
  func commit(from session: HandoffSession) -> Bool {
    guard let plan else { return false }
    do {
      let selectedMapPlaces = selectedMapPlaces
      let (importedSession, unresolved, collisions) = try database.write { db in
        var unresolved: [String] = []
        var collisions: [String] = []
        let imported = try SeedPlan.commit(
          plan, tripID: session.sourceID, session: session, now: date.now, in: db,
          resolveMapMatch: { rowID, stopID, db in
            guard let place = selectedMapPlaces[rowID] else { return nil }
            var capture = place.ideaCapture()
            if capture.kind == nil,
              let rowKind = plan.places.first(where: { $0.id == rowID })?.place.normalizedKind
            {
              capture.kind = rowKind
            }
            if let stopID {
              guard let resolution = try RecommendationResolution.confirm(
                candidateStopID: stopID, capture: capture, in: db
              ) else { return nil }
              if let collision = resolution.collision {
                let duplicate = try TripIdea.find(collision.duplicateID).fetchOne(db)
                let ideaName = try duplicate?.ideaID.flatMap { try Idea.find($0).fetchOne(db)?.name }
                let title = duplicate?.inlineTitle ?? ideaName ?? place.name
                _ = try TripIdea.detachResolvedIdea(
                  from: stopID, deletingOrphanedIdea: resolution.capture.isNew, in: db
                )
                collisions.append("\(place.name) (already on trip as \(title))")
                return nil
              }
              return resolution.capture.ideaID
            }
            let party = try TravelParty.ensureDefault(in: db)
            return try Idea.resolveCapture(capture, travelPartyID: party.id, in: db).ideaID
          },
          unresolvedMapRows: &unresolved
        )
        return (imported, unresolved, collisions)
      }
      try handoffSessionStore.save(importedSession)
      self.plan = nil
      let collidedNames = Set(collisions.compactMap { $0.components(separatedBy: " (already on trip as ").first })
      let rowsNeedingResolution = Array(Set(collisions + unresolved.filter { !collidedNames.contains($0) })).sorted()
      importSummary = rowsNeedingResolution.isEmpty ? nil :
        "Imported. Resolve these rows in Evaluate Recommendations: \(rowsNeedingResolution.joined(separator: ", "))."
      error = nil
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func confirmObviousMatches() {
    guard var plan else { return }
    for index in plan.places.indices {
      var row = plan.places[index]
      guard !row.alreadyOnTrip else { continue }
      if case let .idea(idea) = row.poolMatch {
        row.confirmedIdeaID = idea.id
        row.matchConfirmed = true
      } else if case .none = row.poolMatch,
        let place = mapResults[row.id]?.first(where: { $0.id == preselectedMapPlaces[row.id] })
      {
        selectedMapPlaces[row.id] = place
        row.matchConfirmed = true
      }
      plan.places[index] = row
    }
    for index in plan.stays.indices {
      var row = plan.stays[index]
      guard !row.alreadyOnTrip else { continue }
      if case let .idea(idea) = row.poolMatch {
        row.confirmedIdeaID = idea.id
        row.matchConfirmed = true
      } else if case .none = row.poolMatch,
        let place = mapResults[row.id]?.first(where: { $0.id == preselectedMapPlaces[row.id] })
      {
        selectedMapPlaces[row.id] = place
        row.matchConfirmed = true
      }
      plan.stays[index] = row
    }
    self.plan = plan
  }

  func confirmIdea(_ idea: Idea, rowID: UUID) {
    guard var plan else { return }
    if let index = plan.places.firstIndex(where: { $0.id == rowID }) {
      guard !plan.places[index].alreadyOnTrip else { return }
      plan.places[index].confirmedIdeaID = idea.id
      plan.places[index].matchConfirmed = true
    } else if let index = plan.stays.firstIndex(where: { $0.id == rowID }) {
      guard !plan.stays[index].alreadyOnTrip else { return }
      plan.stays[index].confirmedIdeaID = idea.id
      plan.stays[index].matchConfirmed = true
    }
    self.plan = plan
  }

  func selectMapPlace(_ place: Place, rowID: UUID) {
    guard var plan else { return }
    if let index = plan.places.firstIndex(where: { $0.id == rowID }) {
      guard !plan.places[index].alreadyOnTrip else { return }
      plan.places[index].matchConfirmed = true
    } else if let index = plan.stays.firstIndex(where: { $0.id == rowID }) {
      guard !plan.stays[index].alreadyOnTrip else { return }
      plan.stays[index].matchConfirmed = true
    }
    selectedMapPlaces[rowID] = place
    preselectedMapPlaces[rowID] = place.id
    if let identifier = place.mapItemIdentifier,
      let idea = SeedPoolMatch.match(mapItemIdentifier: identifier, ideas: poolIdeas)
    {
      confirmIdea(idea, rowID: rowID)
      selectedMapPlaces[rowID] = nil
    } else {
      self.plan = plan
    }
  }

  func unconfirmMatch(rowID: UUID) {
    guard var plan else { return }
    selectedMapPlaces[rowID] = nil
    if let index = plan.places.firstIndex(where: { $0.id == rowID }) {
      plan.places[index].confirmedIdeaID = nil
      plan.places[index].matchConfirmed = false
    } else if let index = plan.stays.firstIndex(where: { $0.id == rowID }) {
      plan.stays[index].confirmedIdeaID = nil
      plan.stays[index].matchConfirmed = false
    }
    self.plan = plan
  }

  private func matchRows() async {
    guard let plan else { return }
    let placeRequests = plan.places.compactMap { row -> (UUID, TripCandidate)? in
      if !row.alreadyOnTrip, case .none = row.poolMatch { return (row.id, row.place.candidate) }
      return nil
    }
    let stayRequests = plan.stays.compactMap { row -> (UUID, TripCandidate)? in
      if !row.alreadyOnTrip, case .none = row.poolMatch {
        return (row.id, TripCandidate(name: row.base.name, locality: row.base.locality, searchHint: row.base.searchHint))
      }
      return nil
    }
    let requests = placeRequests + stayRequests
    let tripRegions = self.tripRegions
    matchingRows = Set(requests.map(\.0))
    await withTaskGroup(of: (UUID, [Place]).self) { group in
      var next = 0
      for request in requests.prefix(4) {
        group.addTask { [seedPlaceSearch, tripRegions] in
          (request.0, await seedPlaceSearch.matches(request.1, tripRegions))
        }
        next += 1
      }
      while let (rowID, results) = await group.next() {
        guard !Task.isCancelled else {
          group.cancelAll()
          return
        }
        matchingRows.remove(rowID)
        if let identifierMatch = results.compactMap({ place -> (Place, Idea)? in
          guard let identifier = place.mapItemIdentifier,
            let idea = SeedPoolMatch.match(mapItemIdentifier: identifier, ideas: poolIdeas)
          else { return nil }
          return (place, idea)
        }).first {
          setPoolMatch(identifierMatch.1, rowID: rowID)
        } else {
          mapResults[rowID] = results
          let keys = requestKeys(rowID: rowID)
          if let obvious = SeedMatching.obviousChoice(keys: keys, results: results) {
            preselectedMapPlaces[rowID] = obvious.id
          }
        }
        if next < requests.count {
          let request = requests[next]
          group.addTask { [seedPlaceSearch, tripRegions] in
            (request.0, await seedPlaceSearch.matches(request.1, tripRegions))
          }
          next += 1
        }
      }
    }
    if !Task.isCancelled { matchingFinished = true }
  }

  private func requestKeys(rowID: UUID) -> [String] {
    if let row = plan?.places.first(where: { $0.id == rowID }) {
      return SeedMatchKeys.make(name: row.place.candidate.name, searchHint: row.place.candidate.searchHint)
    }
    if let row = plan?.stays.first(where: { $0.id == rowID }) {
      return SeedMatchKeys.make(name: row.base.name, searchHint: row.base.searchHint)
    }
    return []
  }

  private func setPoolMatch(_ idea: Idea, rowID: UUID) {
    guard var plan else { return }
    if let index = plan.places.firstIndex(where: { $0.id == rowID }) {
      plan.places[index].poolMatch = .idea(idea)
      if let existing = tripIdeas.first(where: {
        $0.ideaID == idea.id && $0.status != .done && $0.status != .skipped
      }) {
        plan.places[index].include = false
        plan.places[index].existingTripIdeaID = existing.id
        plan.places[index].existingStatus = existing.status
        plan.places[index].existingTripTitle = existing.inlineTitle ?? idea.name
      }
    } else if let index = plan.stays.firstIndex(where: { $0.id == rowID }) {
      plan.stays[index].poolMatch = .idea(idea)
      let base = plan.stays[index].base
      if tripStays.contains(where: {
        $0.ideaID == idea.id && $0.checkInDay == base.checkInDay && $0.checkOutDay == base.checkOutDay
      }) {
        plan.stays[index].include = false
        plan.stays[index].alreadyOnTrip = true
      }
    }
    self.plan = plan
  }
}

private struct SeedPlaceSearchClient: Sendable {
  var matches: @Sendable (TripCandidate, [MapRegion]) async -> [Place]
}

extension SeedPlaceSearchClient: DependencyKey {
  static var liveValue: Self {
    @Dependency(\.placeMatcher) var placeMatcher
    return Self(matches: { candidate, regions in await placeMatcher.matches(for: candidate, in: regions) })
  }

  static var testValue: Self { Self(matches: { _, _ in [] }) }
}

private extension DependencyValues {
  var seedPlaceSearch: SeedPlaceSearchClient {
    get { self[SeedPlaceSearchClient.self] }
    set { self[SeedPlaceSearchClient.self] = newValue }
  }
}
