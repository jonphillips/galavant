import Foundation
import GalavantSchema

struct TripDayTimeZoneRefreshKey: Equatable {
  let days: Int
  let tripRegions: [MapRegion]
  let dayRegions: [TripDayRegion]
  let overrides: [TripDayTimeZone]
  let stopCoordinates: [TripCoordinate]
}

extension TripPlanningModel {
  /// The day's resolved zone (override, then day region, then trip centroid): the meal's
  /// zone for booking openings (ADR-0056 D1).
  func dayTimeZone(forDay day: Int) -> TimeZone? {
    resolvedDayTimeZones[day]
  }

  /// Only the zone set by hand on this day. The day header's label and the day's zone
  /// menu show the override, not the inherited zone, so a day with none reads "Trip default".
  func dayTimeZoneOverride(forDay day: Int) -> TimeZone? {
    allTripDayTimeZones.first {
      $0.tripID == tripID && $0.dayNumber == day
    }.flatMap { $0.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) }
  }

  var dayTimeZoneRefreshKey: TripDayTimeZoneRefreshKey {
    TripDayTimeZoneRefreshKey(
      days: trip?.lengthInDays ?? 1,
      tripRegions: tripRegions.sorted { $0.id.uuidString < $1.id.uuidString },
      dayRegions: allTripDayRegions
        .filter { $0.tripID == tripID }
        .sorted { $0.dayNumber < $1.dayNumber },
      overrides: allTripDayTimeZones
        .filter { $0.tripID == tripID }
        .sorted { $0.dayNumber < $1.dayNumber },
      stopCoordinates: plan.scheduledStopCoordinates)
  }

  func refreshDayTimeZones() async {
    guard let trip else {
      resolvedDayTimeZones = [:]
      return
    }
    let expectedKey = dayTimeZoneRefreshKey
    let assignments = allTripDayRegions.filter { $0.tripID == tripID }
    let overrides = allTripDayTimeZones.filter { $0.tripID == tripID }
    let regionIDs = Set(assignments.map(\.regionID) + tripRegions.map(\.id))
    let regionsByID = Dictionary(
      regions.filter { regionIDs.contains($0.id) }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    let coordinate = TripDayTimeZoneResolution.centroidCoordinate(
      regions: tripRegions, fallbackCoordinates: plan.scheduledStopCoordinates)
    let matcher = placeMatcher
    let centroid: TimeZone? = if let coordinate {
      await matcher.timeZone(latitude: coordinate.latitude, longitude: coordinate.longitude)
    } else {
      nil
    }
    let days = trip.lengthInDays > 0 ? Array(1...trip.lengthInDays) : []
    let timeZones = await TripDayTimeZoneResolution.resolve(
      days: days,
      assignments: assignments,
      overrides: overrides,
      regionsByID: regionsByID,
      tripCentroid: centroid,
      timeZoneAt: { latitude, longitude in
        await matcher.timeZone(latitude: latitude, longitude: longitude)
      })
    guard !Task.isCancelled, dayTimeZoneRefreshKey == expectedKey else { return }
    resolvedDayTimeZones = timeZones
  }
}
