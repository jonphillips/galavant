import Foundation

/// Chooses where a recommendation candidate's "search this map" field should look.
///
/// The field must not fall back to the raw camera box (a resolve zoom pinholes it to
/// ~800 m; a candidate in another city then finds nothing) nor to a worldwide search.
/// We already hold the geography to constrain it — no extra model call needed — so the
/// scope is picked most-specific-first:
///   1. a generous box around the candidate's LLM-supplied `locality` point, when known;
///   2. else the trip's own regions — the same geographic contract the Connect button uses.
/// Empty when neither is available, which tells the caller to fall back to viewport bias.
public enum RecommendationCandidateSearch {
  /// Full span (degrees) of the box drawn around a candidate's fuzzy locality — ~39 km
  /// across, so ±~19 km. Wide enough to absorb a rough "town or neighborhood" guess while
  /// still excluding a same-named place in another city.
  public static let localitySpanDegrees = 0.35

  /// Stable identity for the synthesized locality box. Constant on purpose: the box's
  /// *coordinates* change when the focused candidate changes, and `MapRegion` is
  /// `Equatable` by value, so SwiftUI still re-runs the search — no per-candidate id
  /// needed, and the value never collides with a real saved region's id.
  public static let localityRegionID = UUID(uuidString: "00000000-0000-0000-0000-00000000CA57")!

  public static func searchRegions(
    localityLatitude: Double?,
    localityLongitude: Double?,
    tripRegions: [MapRegion]
  ) -> [MapRegion] {
    if let localityLatitude, let localityLongitude {
      return [
        MapRegion(
          id: localityRegionID,
          centerLatitude: localityLatitude,
          centerLongitude: localityLongitude,
          latitudeDelta: localitySpanDegrees,
          longitudeDelta: localitySpanDegrees
        )
      ]
    }
    return tripRegions
  }
}
