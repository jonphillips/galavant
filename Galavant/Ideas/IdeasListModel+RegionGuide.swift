import Foundation
import GalavantSchema

extension IdeasListModel {
  @discardableResult
  func guideButtonTapped() -> RegionGuideScope {
    let lastRegion = UUID(uuidString: lastGuideRegionIDString).flatMap { id in
      regions.first { $0.id == id }
    }
    let scope = RegionGuideScope(
      selectedRegion: selectedRegion,
      activeTripRegions: activeTrip == nil ? [] : tripSubregions,
      lastGuideRegion: lastRegion,
      selectedKindGroups: selectedKindGroups
    )
    return scope
  }
}
