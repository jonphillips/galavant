import Dependencies
import Foundation
import GalavantAI
import SQLiteData

public struct SeedPlanContext: Sendable {
  public var trip: Trip
  public var tripIdeas: [TripIdea]
  public var ideasByID: [Idea.ID: Idea]
  public var poolIdeas: [Idea]
  public var stays: [TripStay]
  public var tripRegions: [MapRegion]
  public var partyRegions: [MapRegion]

  public init(
    trip: Trip, tripIdeas: [TripIdea], ideasByID: [Idea.ID: Idea], stays: [TripStay],
    tripRegions: [MapRegion], partyRegions: [MapRegion], poolIdeas: [Idea] = []
  ) {
    self.trip = trip
    self.tripIdeas = tripIdeas
    self.ideasByID = ideasByID
    self.poolIdeas = poolIdeas
    self.stays = stays
    self.tripRegions = tripRegions
    self.partyRegions = partyRegions
  }
}

public struct SeedTripEdit: Equatable, Sendable {
  public var lengthDays: Int?
  public var includeLength: Bool
  public var year: Int?
  public var knownYear: Int?
  public var quarter: Int?
  public var includeCertainty: Bool
  public var certaintyDisabled: Bool
}

public struct SeedStayPlan: Equatable, Identifiable, Sendable {
  public var base: SeedBase
  public var include: Bool
  public var alreadyOnTrip: Bool
  public var regionID: MapRegion.ID?
  public var poolMatch: SeedPoolMatch
  public var confirmedIdeaID: Idea.ID?
  public var matchConfirmed: Bool
  public var id: UUID { base.id }
  public func note(resolved: Bool = false) -> String? {
    SeedPlan.note([base.why, resolved ? nil : base.placeNotes.map { "About the place: \($0)" }])
  }
}

public struct SeedPlacePlan: Equatable, Identifiable, Sendable {
  public var place: SeedPlace
  public var include: Bool
  public var existingTripIdeaID: TripIdea.ID?
  public var existingStatus: TripIdeaStatus?
  public var existingTripTitle: String?
  public var poolMatch: SeedPoolMatch
  public var confirmedIdeaID: Idea.ID?
  public var matchConfirmed: Bool
  public var alreadyOnTrip: Bool { existingTripIdeaID != nil }
  public var id: UUID { place.id }
  public var title: String { place.candidate.suggestedTitle }
  public var status: TripIdeaStatus {
    switch place.verdict {
    case .core: .shortlisted
    case .considering, .unrecognized: .considering
    case .declined, .deferred: .declined
    }
  }
  public var statusUpdate: Bool { existingStatus.map { $0 != status } ?? false }
  public func note(resolved: Bool = false) -> String? {
    let deferred: String? = if case .deferred = place.verdict {
      SeedPlan.note([place.futureTrip.map { "Deferred — \($0): \(place.reason ?? "")" }])
    } else {
      place.reason
    }
    return SeedPlan.note([
      place.candidate.why, place.candidate.fit, place.candidate.visit, deferred,
      resolved ? nil : place.placeNotes.map { "About the place: \($0)" },
    ])
  }
  public var isRingEligible: Bool {
    place.group != nil && (place.verdict == .core || place.verdict == .considering || isUnrecognized)
  }
  private var isUnrecognized: Bool { if case .unrecognized = place.verdict { true } else { false } }
}

public struct SeedPlan: Equatable, Sendable {
  public var seed: SeedReturn
  public var tripEdit: SeedTripEdit
  public var stays: [SeedStayPlan]
  public var places: [SeedPlacePlan]
  public var warnings: [String]
  public var currentLengthDays: Int

  public var requiredStayLengthDays: Int {
    stays.filter(\.include).map(\.base.checkOutDay).max() ?? currentLengthDays
  }

  public var forcedLengthDays: Int? {
    requiredStayLengthDays > currentLengthDays ? requiredStayLengthDays : nil
  }

  public var effectiveLengthDays: Int {
    let selectedLength = tripEdit.includeLength ? (tripEdit.lengthDays ?? currentLengthDays) : currentLengthDays
    return max(selectedLength, requiredStayLengthDays)
  }

  public var shouldIncludeLength: Bool { effectiveLengthDays > currentLengthDays }

  public func formsRing(at index: Int) -> Bool {
    let row = places[index]
    guard row.include, row.isRingEligible, let group = row.place.group else { return false }
    return formsRing(group: group)
  }

  public func formsRing(group: String) -> Bool {
    places.filter { $0.include && $0.isRingEligible && $0.place.group == group }.count >= 2
  }

  public func effectiveStatus(ofPlaceAt index: Int) -> TripIdeaStatus {
    formsRing(at: index) ? .considering : places[index].status
  }

  public static func make(from seed: SeedReturn, trip: Trip, context: SeedPlanContext) -> SeedPlan {
    let dated = trip.certaintyStage == .dated
    let proposedLength = seed.trip.lengthDays.flatMap { $0 == trip.lengthInDays ? nil : $0 }
    let proposedYear = seed.trip.year.flatMap { $0 == trip.targetYear ? nil : $0 }
    let proposedQuarter = seed.trip.quarter.flatMap { $0 == trip.targetQuarter?.rawValue ? nil : $0 }
    let bothUnspecified = trip.targetYear == nil && trip.targetQuarter == nil
    let existingIdeaIDs = Set(context.tripIdeas.filter { $0.status != .done && $0.status != .skipped }.map(\.id))
    let stays = makeStays(seed.bases, context: context)
    let places = makePlaces(seed.places, context: context, existingIdeaIDs: existingIdeaIDs)
    let requiredStayLength = stays.filter(\.include).map(\.base.checkOutDay).max() ?? trip.lengthInDays
    let lengthDays = max(proposedLength ?? trip.lengthInDays, requiredStayLength)
    let hasYear = seed.trip.year != nil || trip.targetYear != nil
    return SeedPlan(
      seed: seed,
      tripEdit: SeedTripEdit(
        lengthDays: lengthDays == trip.lengthInDays ? nil : lengthDays,
        includeLength: lengthDays != trip.lengthInDays
          && ((proposedLength != nil && trip.lengthInDays == Trip.defaultLengthInDays) || requiredStayLength > trip.lengthInDays),
        year: proposedYear, knownYear: seed.trip.year ?? trip.targetYear, quarter: proposedQuarter,
        includeCertainty: !dated && hasYear && (proposedYear != nil || proposedQuarter != nil) && bothUnspecified,
        certaintyDisabled: dated
      ),
      stays: stays, places: places, warnings: seed.warnings, currentLengthDays: trip.lengthInDays
    )
  }

  private static func makeStays(_ bases: [SeedBase], context: SeedPlanContext) -> [SeedStayPlan] {
    bases.map { base in
      let match = SeedPoolMatch.match(
        keys: SeedMatchKeys.make(name: base.name, searchHint: base.searchHint),
        locality: base.locality, ideas: context.poolIdeas
      )
      let poolIdeaID: Idea.ID? = if case let .idea(idea) = match { idea.id } else { nil }
      let already = context.stays.contains { stay in
        let title = stay.inlineTitle ?? stay.ideaID.flatMap { context.ideasByID[$0]?.name }
        let samePlace = RecommendationCandidateIdentity.normalized(title) == RecommendationCandidateIdentity.normalized(base.name)
          || (poolIdeaID != nil && stay.ideaID == poolIdeaID)
        return samePlace
          && stay.checkInDay == base.checkInDay && stay.checkOutDay == base.checkOutDay
      }
      return SeedStayPlan(
        base: base, include: !already, alreadyOnTrip: already,
        regionID: matchingRegion(base.region, context: context), poolMatch: match,
        confirmedIdeaID: nil, matchConfirmed: false
      )
    }
  }

  private static func makePlaces(
    _ seedPlaces: [SeedPlace], context: SeedPlanContext, existingIdeaIDs: Set<TripIdea.ID>
  ) -> [SeedPlacePlan] {
    seedPlaces.map { place -> SeedPlacePlan in
      let matchedByName = RecommendationCandidateSet.liveTripIdea(
        matching: place.candidate, in: context.tripIdeas, ideasByID: context.ideasByID
      )
      let poolMatch = SeedPoolMatch.match(
        keys: SeedMatchKeys.make(name: place.candidate.name, searchHint: place.candidate.searchHint),
        locality: place.candidate.locality, ideas: context.poolIdeas
      )
      let poolIdeaID: Idea.ID? = if case let .idea(idea) = poolMatch { idea.id } else { nil }
      let matchedByPoolIdentity = poolIdeaID.flatMap { ideaID in
        context.tripIdeas.first { $0.ideaID == ideaID && existingIdeaIDs.contains($0.id) }
      }
      let matched = matchedByName ?? matchedByPoolIdentity
      let already = matched.map { existingIdeaIDs.contains($0.id) } ?? false
      return SeedPlacePlan(
        place: place,
        include: !already,
        existingTripIdeaID: matched?.id,
        existingStatus: already ? matched?.status : nil,
        existingTripTitle: matched.map { $0.inlineTitle ?? $0.ideaID.flatMap { context.ideasByID[$0]?.name } ?? place.candidate.suggestedTitle },
        poolMatch: poolMatch,
        confirmedIdeaID: nil,
        matchConfirmed: false
      )
    }
  }

  public var ignoredGroups: [String] {
    let groups = Set(places.compactMap { $0.isRingEligible ? $0.place.group : nil })
    return groups.sorted().filter { !formsRing(group: $0) }
  }

  /// Import the reviewed plan into the caller's active database transaction.
  /// The returned session carries candidate links and is saved device-locally by the caller.
  @discardableResult
  public static func commit(
    _ plan: SeedPlan,
    tripID: Trip.ID,
    session: HandoffSession,
    now: Date,
    in db: Database
  ) throws -> HandoffSession {
    var unresolved: [String] = []
    return try commit(
      plan, tripID: tripID, session: session, now: now, in: db,
      resolveMapMatch: nil, unresolvedMapRows: &unresolved
    )
  }

  @discardableResult
  public static func commit(
    _ plan: SeedPlan,
    tripID: Trip.ID,
    session suppliedSession: HandoffSession,
    now: Date,
    in db: Database,
    resolveMapMatch: ((UUID, TripIdea.ID?, Database) throws -> Idea.ID?)? = nil,
    unresolvedMapRows: inout [String]
  ) throws -> HandoffSession {
    if !plan.seed.narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      plan.seed.narrative.utf8.count > 512_000
    {
      // Match TripDocument.add's existing 512 KB cap before beginning this transaction.
      throw TripDocumentError.tooLarge
    }
    try applyTripEdits(plan, tripID: tripID, in: db)
    try commitStays(
      plan.stays, tripID: tripID, now: now, resolveMapMatch: resolveMapMatch,
      unresolvedMapRows: &unresolvedMapRows, in: db
    )
    var session = try commitPlaces(
      plan, tripID: tripID, session: suppliedSession, now: now,
      resolveMapMatch: resolveMapMatch, unresolvedMapRows: &unresolvedMapRows, in: db
    )
    try addDocument(plan.seed.narrative, tripID: tripID, now: now, in: db)
    session.importedAt = now
    session.status = .imported
    return session
  }

  private static func applyTripEdits(_ plan: SeedPlan, tripID: Trip.ID, in db: Database) throws {
    if plan.shouldIncludeLength {
      try Trip.setLength(plan.effectiveLengthDays, tripID: tripID, in: db)
    }
    let edit = plan.tripEdit
    guard edit.includeCertainty, !edit.certaintyDisabled else { return }
    guard let trip = try Trip.find(tripID).fetchOne(db) else { throw TripError.creationFailed }
    guard let year = edit.year ?? trip.targetYear else { return }
    let quarter = edit.quarter.flatMap(Quarter.init(rawValue:)) ?? trip.targetQuarter
    try Trip.update(Trip.Draft(trip), certainty: .targeted(year: year, quarter: quarter), in: db)
  }

  private static func commitStays(
    _ stays: [SeedStayPlan], tripID: Trip.ID, now: Date,
    resolveMapMatch: ((UUID, TripIdea.ID?, Database) throws -> Idea.ID?)?,
    unresolvedMapRows: inout [String], in db: Database
  ) throws {
    for stayPlan in stays where stayPlan.include && !stayPlan.alreadyOnTrip {
      let base = stayPlan.base
      var ideaID = stayPlan.matchConfirmed ? stayPlan.confirmedIdeaID : nil
      if ideaID == nil, stayPlan.matchConfirmed, case .none = stayPlan.poolMatch {
        ideaID = try resolveMapMatch?(base.id, nil, db)
        if ideaID == nil, resolveMapMatch != nil { unresolvedMapRows.append(base.name) }
      }
      let note = stayPlan.note(resolved: ideaID != nil)
      let stayID: TripStay.ID
      if let ideaID {
        stayID = try TripStay.create(
          tripID: tripID, ideaID: ideaID, note: note,
          checkInDay: base.checkInDay, checkOutDay: base.checkOutDay, in: db
        )
        try recordPlaceNotes(base.placeNotes, ideaID: ideaID, now: now, in: db)
      } else {
        stayID = try TripStay.createFreeform(
          tripID: tripID, title: base.name, note: note,
          checkInDay: base.checkInDay, checkOutDay: base.checkOutDay, in: db
        )
      }
      if base.bookAhead { try TripStay.setBookingStatus(.toBook, stayID: stayID, in: db) }
      if let regionID = stayPlan.regionID {
        for night in base.checkInDay..<base.checkOutDay {
          try TripDayRegion.setRegion(regionID, forTrip: tripID, day: night, in: db)
        }
      }
    }
  }

  private static func commitPlaces(
    _ plan: SeedPlan, tripID: Trip.ID, session suppliedSession: HandoffSession,
    now: Date,
    resolveMapMatch: ((UUID, TripIdea.ID?, Database) throws -> Idea.ID?)?,
    unresolvedMapRows: inout [String], in db: Database
  ) throws -> HandoffSession {
    let includedPlaces = plan.places.filter(\.include)
    let candidates = includedPlaces.map { $0.place.candidate }
    var session = suppliedSession
    _ = try session.storeRecommendationCandidates(candidates)
    var importedIDs: [String: TripIdea.ID] = [:]
    var ringMembers: [String: [TripIdea.ID]] = [:]
    var shortlistRank = try TripIdea.nextShortlistRank(tripID: tripID, in: db)
    for (index, row) in plan.places.enumerated() where row.include {
      if let id = row.existingTripIdeaID {
        if row.statusUpdate { try TripIdea.setStatus(row.status, stopID: id, in: db) }
        if row.matchConfirmed, let ideaID = row.confirmedIdeaID {
          _ = try TripIdea.attachResolvedIdea(ideaID, to: id, in: db)
          try recordPlaceNotes(row.place.placeNotes, ideaID: ideaID, now: now, in: db)
        }
        if plan.formsRing(at: index), let group = row.place.group {
          try TripIdea.setStatus(.considering, stopID: id, in: db)
          ringMembers[group, default: []].append(id)
        }
        importedIDs[row.place.candidate.id.uuidString] = id
        continue
      }
      let status = plan.effectiveStatus(ofPlaceAt: index)
      let rank = status == .shortlisted ? shortlistRank : try TripIdea.nextStopRank(tripID: tripID, in: db)
      if status == .shortlisted { shortlistRank += 1 }
      let resolvedIdeaID: Idea.ID?
      if row.matchConfirmed, let confirmedIdeaID = row.confirmedIdeaID {
        resolvedIdeaID = confirmedIdeaID
      } else {
        resolvedIdeaID = nil
      }
      let stop = try TripIdea.commitSeedRow(
        candidate: row.place.candidate, status: status,
        note: row.note(resolved: resolvedIdeaID != nil || (row.matchConfirmed && resolveMapMatch != nil)),
        bookingStatus: row.place.candidate.bookAhead == true && status != .declined ? .toBook : nil,
        shortlistRank: rank, ideaID: resolvedIdeaID, into: tripID, in: db
      )
      var finalIdeaID = resolvedIdeaID
      if finalIdeaID == nil, row.matchConfirmed, case .none = row.poolMatch {
        finalIdeaID = try resolveMapMatch?(row.id, stop.id, db)
        if let finalIdeaID {
          _ = try TripIdea.attachResolvedIdea(finalIdeaID, to: stop.id, in: db)
        } else if resolveMapMatch != nil {
          try TripIdea.find(stop.id).update { $0.inlineNote = #bind(row.note(resolved: false)) }.execute(db)
          unresolvedMapRows.append(row.title)
        }
      }
      try recordPlaceNotes(row.place.placeNotes, ideaID: finalIdeaID, now: now, in: db)
      importedIDs[row.place.candidate.id.uuidString] = stop.id
      if plan.formsRing(at: index), let group = row.place.group { ringMembers[group, default: []].append(stop.id) }
    }
    for memberIDs in ringMembers.values where memberIDs.count >= 2 {
      _ = try TripIdea.chooseOne(among: memberIDs, in: db)
    }
    for candidate in candidates {
      if let id = importedIDs[candidate.id.uuidString] { session.link(candidateID: candidate.id, to: id) }
    }
    session.importedAt = now
    return session
  }

  private static func recordPlaceNotes(
    _ notes: String?, ideaID: Idea.ID?, now: Date, in db: Database
  ) throws {
    guard let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty,
      let ideaID
    else { return }
    let party = try TravelParty.ensureDefault(in: db)
    _ = try IdeaEvaluation.create(
      travelPartyID: party.id, ideaID: ideaID, sourceName: "Trip research", kind: .text,
      nativeValueText: notes, nativeDisplay: "Research note", evaluationDate: now,
      confidence: .inferred, staleness: .current, summary: notes, in: db
    )
  }

  private static func addDocument(_ narrative: String, tripID: Trip.ID, now: Date, in db: Database) throws {
    guard !narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    _ = try TripDocument.add(
      tripID: tripID,
      title: "Founding conversation — \(now.formatted(date: .abbreviated, time: .omitted))",
      body: narrative, origin: .seed, now: now, in: db
    )
  }

  fileprivate static func note(_ parts: [String?]) -> String? {
    let values = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return values.isEmpty ? nil : values.joined(separator: "\n\n")
  }

  private static func matchingRegion(_ name: String?, context: SeedPlanContext) -> MapRegion.ID? {
    guard let name else { return nil }
    func matches(_ regions: [MapRegion]) -> [MapRegion] {
      regions.filter { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
    if let region = matches(context.tripRegions).first { return region.id }
    let partyMatches = matches(context.partyRegions)
    return partyMatches.count == 1 ? partyMatches[0].id : nil
  }

}

extension TripIdea {
  /// Insert a reviewed seed place as a freeform trip row with its selected verdict.
  @discardableResult
  public static func commitSeedRow(
    candidate: TripCandidate, status: TripIdeaStatus, note: String?, bookingStatus: BookingStatus?,
    shortlistRank: Int, ideaID: Idea.ID? = nil, into tripID: Trip.ID, in db: Database
  ) throws -> TripIdea {
    let id = UUID()
    let row = TripIdea(
      id: id, tripID: tripID, ideaID: ideaID,
      inlineTitle: ideaID == nil ? (candidate.name ?? candidate.suggestedTitle) : nil,
      inlineNote: note, status: status, shortlistRank: shortlistRank, bookingStatus: bookingStatus
    )
    try TripIdea.insert { TripIdea.Draft(row) }.execute(db)
    guard let committed = try TripIdea.find(id).fetchOne(db) else { throw TripError.creationFailed }
    return committed
  }
}

private extension Date {
  var calendarYear: Int { Calendar.current.component(.year, from: self) }
}
