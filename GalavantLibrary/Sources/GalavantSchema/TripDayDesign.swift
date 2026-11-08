import Foundation

/// The editable design facts shown for one trip day (ADR-0054). Dates are a
/// display projection of the trip start; day numbers remain the stored identity.
public struct TripDayDesign: Identifiable, Equatable, Sendable {
  public var day: Int
  public var date: Date?
  public var regionID: MapRegion.ID?
  public var timeZoneIdentifier: String?
  public var summary: String?
  public var stayTitle: String?
  public var id: Int { day }

  public init(
    day: Int, date: Date?, regionID: MapRegion.ID?, timeZoneIdentifier: String?,
    summary: String?, stayTitle: String?
  ) {
    self.day = day
    self.date = date
    self.regionID = regionID
    self.timeZoneIdentifier = timeZoneIdentifier
    self.summary = summary
    self.stayTitle = stayTitle
  }

  public static func rows(
    trip: Trip, dayRegions: [TripDayRegion], dayTimeZones: [TripDayTimeZone],
    dayNotes: [TripDayNote], stays: [ResolvedStay]
  ) -> [TripDayDesign] {
    guard trip.lengthInDays > 0 else { return [] }
    return (1...trip.lengthInDays).map { day in
      let nightStay = day < trip.lengthInDays
        ? stays.filter { $0.stay.nights.contains(day) }
          .max { $0.stay.checkInDay < $1.stay.checkInDay }
        : nil
      return TripDayDesign(
        day: day,
        date: trip.date(forDay: day),
        regionID: dayRegions.first { $0.tripID == trip.id && $0.dayNumber == day }?.regionID,
        timeZoneIdentifier: dayTimeZones.first {
          $0.tripID == trip.id && $0.dayNumber == day
        }?.timeZoneIdentifier,
        summary: dayNotes.first { $0.tripID == trip.id && $0.dayNumber == day }?.note,
        stayTitle: nightStay?.content.title)
    }
  }
}
