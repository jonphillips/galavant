import Foundation
import GalavantSchema

extension TripPlanningModel {
  /// Stable input key for the fallback trip time-zone centroid. Resolves only
  /// scheduled stop coordinates instead of rebuilding the full `TripPlan`.
  var tripTimeZoneCoordinateKey: String {
    let ideasByID = ideaByID
    let resolvedEntries = entries.filter { entry in
      if let ideaID = entry.ideaID { return ideasByID[ideaID] != nil }
      return !(entry.inlineTitle?.isEmpty ?? true)
    }
    let entriesByAlternativeGroup = Dictionary(grouping: resolvedEntries, by: \.alternativeGroupID)
    let activeEntryByAlternativeGroup = Dictionary(
      uniqueKeysWithValues: entriesByAlternativeGroup.compactMap { groupID, members -> (UUID, UUID)? in
        guard let groupID, members.count > 1 else { return nil }
        let ordered = TripIdea.canonicalAlternativeOrder(members)
        guard let active = ordered.first(where: \.isActive) ?? ordered.first else { return nil }
        return (groupID, active.id)
      })

    return resolvedEntries.compactMap { entry -> String? in
      guard entry.status == .scheduled, entry.dayNumber != nil else { return nil }
      if let groupID = entry.alternativeGroupID,
        let activeID = activeEntryByAlternativeGroup[groupID],
        entry.id != activeID
      {
        return nil
      }
      if let ideaID = entry.ideaID,
        let idea = ideasByID[ideaID],
        let latitude = idea.latitude,
        let longitude = idea.longitude
      {
        return "\(latitude),\(longitude)"
      }
      guard entry.ideaID == nil,
        let title = entry.inlineTitle,
        !title.isEmpty,
        let latitude = entry.inlineLatitude,
        let longitude = entry.inlineLongitude
      else { return nil }
      return "\(latitude),\(longitude)"
    }
    .sorted()
    .joined(separator: ";")
  }
}
