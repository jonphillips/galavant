import Foundation
import SQLiteData

extension TripIdea {
  /// Mark a set of still-considering candidate stops as interchangeable options.
  /// This reuses ADR-0035's existing `alternativeGroupID` ring rather than adding a
  /// recommendation-specific relation. The caller can make the currently selected
  /// candidate active; otherwise canonical order provides a stable default.
  @discardableResult
  public static func chooseOne(
    among candidateStopIDs: [TripIdea.ID],
    activeStopID: TripIdea.ID? = nil,
    groupID: UUID = UUID(),
    in db: Database
  ) throws -> UUID? {
    var seen = Set<TripIdea.ID>()
    let uniqueIDs = candidateStopIDs.filter { seen.insert($0).inserted }
    guard uniqueIDs.count > 1 else { return nil }

    let candidates = try uniqueIDs.compactMap { try TripIdea.find($0).fetchOne(db) }
    guard
      candidates.count == uniqueIDs.count,
      let tripID = candidates.first?.tripID,
      candidates.allSatisfy({ $0.tripID == tripID && $0.status == .considering })
    else { return nil }

    let existingGroups = Set(candidates.compactMap(\.alternativeGroupID))
    if existingGroups.count == 1, candidates.allSatisfy({ $0.alternativeGroupID != nil }) {
      return existingGroups.first
    }
    guard existingGroups.isEmpty else { return nil }

    let resolvedActiveID = activeStopID ?? canonicalAlternativeOrder(candidates).first?.id
    guard let resolvedActiveID, uniqueIDs.contains(resolvedActiveID) else { return nil }
    for candidate in candidates {
      try TripIdea.find(candidate.id)
        .update {
          $0.alternativeGroupID = #bind(groupID)
          $0.isActive = #bind(candidate.id == resolvedActiveID)
        }
        .execute(db)
    }
    return groupID
  }

  /// Reconstitute a ring after an undo restores a deleted member. The snapshot is
  /// only applied while every former member is still a considering stop in the
  /// same trip, so undo never overwrites a newer scheduling decision.
  @discardableResult
  public static func restoreAlternativeRing(
    memberIDs: [TripIdea.ID],
    activeStopID: TripIdea.ID,
    groupID: UUID,
    in db: Database
  ) throws -> Bool {
    var seen = Set<TripIdea.ID>()
    let uniqueIDs = memberIDs.filter { seen.insert($0).inserted }
    guard uniqueIDs.count > 1, uniqueIDs.contains(activeStopID) else { return false }

    let members = try uniqueIDs.compactMap { try TripIdea.find($0).fetchOne(db) }
    guard
      members.count == uniqueIDs.count,
      let tripID = members.first?.tripID,
      members.allSatisfy({ $0.tripID == tripID && $0.status == .considering })
    else { return false }

    for member in members {
      try TripIdea.find(member.id)
        .update {
          $0.alternativeGroupID = #bind(groupID)
          $0.isActive = #bind(member.id == activeStopID)
        }
        .execute(db)
    }
    return true
  }

  /// The stable order of peers in an alternatives ring. `shortlistRank` keeps a
  /// ring's usual shortlist intent, while the UUID tiebreak makes concurrent
  /// same-rank writes converge identically on every device (ADR-0035).
  public static func canonicalAlternativeOrder(_ members: [TripIdea]) -> [TripIdea] {
    members.sorted {
      ($0.shortlistRank, $0.id.uuidString) < ($1.shortlistRank, $1.id.uuidString)
    }
  }

  /// One effective member per alternatives ring, without mutating storage. An
  /// ordinary stop is its own effective member. This raw-record variant cannot
  /// see deleted pool ideas; `TripPlan` performs the same reconciliation after
  /// resolving content so an orphaned stored active cannot hide a valid peer.
  public static func effectiveActiveEntries(_ entries: [TripIdea]) -> [TripIdea] {
    let groupedEntries = entries.compactMap { entry -> (UUID, TripIdea)? in
      entry.alternativeGroupID.map { ($0, entry) }
    }
    let groups = Dictionary(grouping: groupedEntries, by: \.0)
      .mapValues { $0.map(\.1) }
    let activeIDs: [UUID: TripIdea.ID] = Dictionary(
      uniqueKeysWithValues: groups.compactMap { groupID, members -> (UUID, TripIdea.ID)? in
        let ordered = canonicalAlternativeOrder(members)
        guard let winner = ordered.first(where: \.isActive) ?? ordered.first else { return nil }
        return (groupID, winner.id)
      })
    return entries.filter { entry in
      guard let groupID = entry.alternativeGroupID else { return true }
      return activeIDs[groupID] == entry.id
    }
  }

  static func alternativeMembers(containing entry: TripIdea, in db: Database) throws -> [TripIdea] {
    guard let groupID = entry.alternativeGroupID else { return [entry] }
    return canonicalAlternativeOrder(
      try TripIdea
        .where { $0.tripID.eq(entry.tripID) }
        .fetchAll(db)
        .filter { $0.alternativeGroupID == groupID })
  }

  static func effectiveActiveMember(in members: [TripIdea]) -> TripIdea? {
    let ordered = canonicalAlternativeOrder(members)
    return ordered.first(where: \.isActive) ?? ordered.first
  }

  static func normalizeAlternativeMembers(_ members: [TripIdea], in db: Database) throws {
    guard let groupID = members.first?.alternativeGroupID else { return }
    if members.count == 1, let member = members.first {
      try TripIdea.find(member.id)
        .update {
          $0.alternativeGroupID = #bind(nil)
          $0.isActive = #bind(true)
        }
        .execute(db)
      try TripAlternativeGroup.remove(groupID: groupID, in: db)
      return
    }
    guard let active = effectiveActiveMember(in: members) else { return }
    for member in members {
      try TripIdea.find(member.id)
        .update {
          $0.alternativeGroupID = #bind(groupID)
          $0.isActive = #bind(member.id == active.id)
        }
        .execute(db)
    }
  }

  static func updateSharedSlot(
    members: [TripIdea],
    status: TripIdeaStatus,
    schedule: Schedule,
    in db: Database
  ) throws {
    // Every member occupies one position, so the shared slot's `dayRank` (ADR-0033)
    // propagates alongside the schedule columns — the effective active member's
    // rank is canonical, so a raced divergence self-heals here. For an ordinary
    // stop this rewrites its own rank, an identity write.
    let slotDayRank = effectiveActiveMember(in: members)?.dayRank ?? members.first?.dayRank ?? 0
    for member in members {
      var updated = member
      updated.status = status
      updated.apply(schedule)
      try TripIdea.find(member.id)
        .update {
          $0.status = #bind(updated.status)
          $0.dayNumber = #bind(updated.dayNumber)
          $0.dayPart = #bind(updated.dayPart)
          $0.startTime = #bind(updated.startTime)
          $0.endTime = #bind(updated.endTime)
          $0.dayRank = #bind(slotDayRank)
        }
        .execute(db)
      }
    try normalizeAlternativeMembers(members, in: db)
  }

  static func reindexShortlist(tripID: Trip.ID, in db: Database) throws {
    let entries = try TripIdea
      .where { $0.tripID.eq(tripID) }
      .fetchAll(db)
      .filter { $0.status == .shortlisted }
      .sorted { ($0.shortlistRank, $0.id.uuidString) < ($1.shortlistRank, $1.id.uuidString) }
    for (rank, entry) in entries.enumerated() {
      try TripIdea.find(entry.id).update { $0.shortlistRank = rank }.execute(db)
    }
  }
}
