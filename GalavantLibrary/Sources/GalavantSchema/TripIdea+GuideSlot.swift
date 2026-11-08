import SQLiteData

extension TripIdea {
  /// Take one option out of a ring and return it to the trip shortlist. Remaining
  /// members keep the slot and are normalized to exactly one active choice.
  public static func detachAlternative(stopID: TripIdea.ID, in db: Database) throws {
    guard let entry = try TripIdea.find(stopID).fetchOne(db), entry.alternativeGroupID != nil else { return }
    let members = try alternativeMembers(containing: entry, in: db)
    try TripIdea.find(stopID)
      .update {
        $0.status = #bind(.shortlisted)
        $0.dayNumber = #bind(nil)
        $0.dayPart = #bind(nil)
        $0.startTime = #bind(nil)
        $0.endTime = #bind(nil)
        $0.alternativeGroupID = #bind(nil)
        $0.isActive = #bind(true)
      }
      .execute(db)
    try normalizeAlternativeMembers(members.filter { $0.id != stopID }, in: db)
  }
}
