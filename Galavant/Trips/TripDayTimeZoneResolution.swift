import Foundation
import GalavantSchema

enum TripDayTimeZoneResolution {
  static func centroidCoordinate(
    regions: [MapRegion], fallbackCoordinates: [TripCoordinate]
  ) -> TripCoordinate? {
    if let box = MapRegion.boundingBox(of: regions) {
      return TripCoordinate(latitude: box.centerLatitude, longitude: box.centerLongitude)
    }
    guard !fallbackCoordinates.isEmpty else { return nil }
    return TripCoordinate(
      latitude: fallbackCoordinates.map(\.latitude).reduce(0, +) / Double(fallbackCoordinates.count),
      longitude: fallbackCoordinates.map(\.longitude).reduce(0, +) / Double(fallbackCoordinates.count))
  }

  static func resolve(
    days: [DayNumber],
    assignments: [TripDayRegion],
    overrides: [TripDayTimeZone],
    regionsByID: [MapRegion.ID: MapRegion],
    tripCentroid: TimeZone?,
    timeZoneAt: @escaping @Sendable (Double, Double) async -> TimeZone?
  ) async -> [DayNumber: TimeZone] {
    var regionZones: [DayNumber: TimeZone] = [:]
    var zonesByRegionID: [MapRegion.ID: TimeZone] = [:]
    for assignment in assignments {
      if let zone = zonesByRegionID[assignment.regionID] {
        regionZones[assignment.dayNumber] = zone
      } else if let region = regionsByID[assignment.regionID],
        let zone = await timeZoneAt(region.centerLatitude, region.centerLongitude)
      {
        zonesByRegionID[assignment.regionID] = zone
        regionZones[assignment.dayNumber] = zone
      }
    }

    let overrideZones = Dictionary(
      overrides.compactMap { row in
        row.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)).map { (row.dayNumber, $0) }
      }, uniquingKeysWith: { first, _ in first })
    return TripDayTimeZoneMap.resolve(
      days: days,
      overrides: overrideZones,
      dayRegions: regionZones,
      tripCentroid: tripCentroid)
  }
}
