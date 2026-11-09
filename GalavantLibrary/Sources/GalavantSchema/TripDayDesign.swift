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
  public var lock: DayLock?
  public var id: Int { day }

  public init(
    day: Int, date: Date?, regionID: MapRegion.ID?, timeZoneIdentifier: String?,
    summary: String?, stayTitle: String?, lock: DayLock? = nil
  ) {
    self.day = day
    self.date = date
    self.regionID = regionID
    self.timeZoneIdentifier = timeZoneIdentifier
    self.summary = summary
    self.stayTitle = stayTitle
    self.lock = lock
  }

  public static func rows(
    trip: Trip, dayRegions: [TripDayRegion], dayTimeZones: [TripDayTimeZone],
    dayNotes: [TripDayNote], stays: [ResolvedStay], stops: [ResolvedStop], now: Date
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
        stayTitle: nightStay?.content.title,
        lock: lock(for: day, trip: trip, stops: stops, now: now))
    }
  }

  private static func lock(for day: Int, trip: Trip, stops: [ResolvedStop], now: Date) -> DayLock? {
    if let stop = stops
      .filter({ $0.entry.dayNumber == day })
      .sorted(by: { $0.content.title < $1.content.title })
      .first(where: { $0.entry.pinnedDate != nil || $0.entry.bookingStatus == .booked }) {
      return .booking(title: stop.content.title)
    }
    guard let date = trip.date(forDay: day) else { return nil }
    return Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: now) ? .past : nil
  }

  public var lockCaption: String? {
    guard let lock else { return nil }
    return switch lock {
    case let .booking(title): "Has a booking: \(title)"
    case .past: "This day has already happened"
    }
  }
}
