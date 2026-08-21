import GalavantPlaces
import GalavantSchema
import MapKit
import SwiftUI

@MainActor
enum MapPlaceResolver {
  /// Resolve an Apple Maps feature without projecting it into Galavant's value type.
  /// The Ideas map retains this framework object so Apple's native detail surface can
  /// present the same place the user tapped.
  static func mapItem(for feature: MapFeature) async -> MKMapItem? {
    try? await MKMapItemRequest(feature: feature).mapItem
  }

  static func place(for mapItem: MKMapItem) -> Place {
    Place(mapItem: mapItem)
  }

  static func place(for feature: MapFeature) async -> Place {
    if let item = await mapItem(for: feature) {
      return place(for: item)
    }
    return Place(
      id: UUID(),
      name: feature.title ?? String(localized: "Pinned Location"),
      latitude: feature.coordinate.latitude,
      longitude: feature.coordinate.longitude,
      kind: feature.pointOfInterestCategory.flatMap {
        IdeaKind(pointOfInterestCategoryRawValue: $0.rawValue)
      }
    )
  }
}
