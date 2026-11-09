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
    dayNotes: [TripDayNote], stays: [ResolvedStay], stops: [TripIdea],
    ideas: [Idea], now: Date
  ) -> [TripDayDesign] {
    guard trip.lengthInDays > 0 else { return [] }
    let ideasByID = Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let locks = locks(trip: trip, stops: stops, now: now) { stop in
      if let title = stop.inlineTitle { return title }
      return stop.ideaID.flatMap { ideasByID[$0]?.name }
    }
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
        lock: locks[day])
    }
  }

  public static func locks(
    trip: Trip,
    stops: [TripIdea],
    now: Date,
    bookingTitle: (TripIdea) throws -> String?
  ) rethrows -> [Int: DayLock] {
    guard trip.lengthInDays > 0 else { return [:] }
    let entriesByDay = Dictionary(grouping: stops.filter {
      $0.tripID == trip.id && (1...trip.lengthInDays).contains($0.dayNumber ?? 0)
    }) { $0.dayNumber! }
    var locks: [Int: DayLock] = [:]
    for day in 1...trip.lengthInDays {
      let booking = entriesByDay[day]?
        .filter { $0.pinnedDate != nil || $0.bookingStatus == .booked }
        .sorted { $0.id.uuidString < $1.id.uuidString }
        .first
      if let booking {
        locks[day] = .booking(title: try bookingTitle(booking) ?? "Unknown stop")
      } else if let date = trip.date(forDay: day),
        Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: now) {
        locks[day] = .past
      }
    }
    return locks
  }

  public var lockCaption: String? {
    guard let lock else { return nil }
    return switch lock {
    case let .booking(title): "Has a booking: \(title)"
    case .past: "This day has already happened"
    }
  }
}
