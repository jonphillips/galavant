import Foundation
import GalavantSchema

extension IdeasListModel {
  func guideButtonTapped() {
    let lastRegion = UUID(uuidString: lastGuideRegionIDString).flatMap { id in
      regions.first { $0.id == id }
    }
    destination = .guide(RegionGuideScope(
      selectedRegion: selectedRegion,
      activeTripRegions: activeTrip == nil ? [] : scopeRegions,
      lastGuideRegion: lastRegion,
      selectedKindGroups: selectedKindGroups,
      preferredTripID: activeTrip?.id
    ))
  }
}
