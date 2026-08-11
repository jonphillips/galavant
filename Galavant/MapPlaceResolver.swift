import GalavantPlaces
import GalavantSchema
import MapKit
import SwiftUI

@MainActor
enum MapPlaceResolver {
  static func place(for feature: MapFeature) async -> Place {
    if let item = try? await MKMapItemRequest(feature: feature).mapItem {
      return Place(mapItem: item)
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
