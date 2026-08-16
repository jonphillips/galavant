import Foundation

/// A read-only, weather-free-by-default view of the active day in a `TripPlan`.
///
/// This is deliberately a value derived from the itinerary stream rather than a
/// second itinerary model. The app layer may later fill an optional weather
/// request, but no forecast belongs in this projection.
public struct TodayProjection: Equatable, Sendable {
  public struct DayContext: Equatable, Sendable {
    public var date: Date
    public var dayNumber: Int
    public var locality: String?

    public init(date: Date, dayNumber: Int, locality: String?) {
      self.date = date
      self.dayNumber = dayNumber
      self.locality = locality
    }
  }

  public struct Next: Equatable, Sendable {
    public var item: ItineraryItem
    public var leaveBy: LeaveBy?
    /// `nil` is the complete, ordinary no-weather state.
    public var weatherAnchor: WeatherAnchor?

    public init(item: ItineraryItem, leaveBy: LeaveBy?, weatherAnchor: WeatherAnchor?) {
      self.item = item
      self.leaveBy = leaveBy
      self.weatherAnchor = weatherAnchor
    }
  }

  public enum RemainingItem: Equatable, Sendable {
    case earlierToday(count: Int)
    case item(ItineraryItem)
  }

  public struct Tonight: Equatable, Sendable {
    public var stay: ResolvedStay
    public var nightNumber: Int
    public var totalNights: Int

    public init(stay: ResolvedStay, nightNumber: Int, totalNights: Int) {
      self.stay = stay
      self.nightNumber = nightNumber
      self.totalNights = totalNights
    }
  }

  public struct Tomorrow: Equatable, Sendable {
    public var dayContext: DayContext
    /// Orientation only: a lodging-transfer ETA has no weather request.
    public var transfer: TravelConnector?

    public init(dayContext: DayContext, transfer: TravelConnector?) {
      self.dayContext = dayContext
      self.transfer = transfer
    }
  }

  public var dayContext: DayContext
  public var next: Next?
  public var remaining: [RemainingItem]
  public var tonight: Tonight?
  public var tomorrow: Tomorrow?

  public init(
    dayContext: DayContext,
    next: Next?,
    remaining: [RemainingItem],
    tonight: Tonight?,
    tomorrow: Tomorrow?
  ) {
    self.dayContext = dayContext
    self.next = next
    self.remaining = remaining
    self.tonight = tonight
    self.tomorrow = tomorrow
  }

  /// Resolves Today only while `now` falls on a day of this trip.
  ///
  /// `leaveByBuffer` is supplied by the caller because ADR-0038 requires a
  /// buffer but does not make its size a domain fact. Keeping it explicit avoids
  /// a hidden timing policy in the schema module.
  public static func resolve(
    from tripPlan: TripPlan,
    now: Date,
    tripStartDate: Date,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    effectiveModes: [LegKey: TransportMode] = [:],
    leaveByBuffer: TimeInterval
  ) -> Self? {
    let calendar = Calendar.current
    guard let dayNumber = dayNumber(for: now, tripStartDate: tripStartDate, calendar: calendar),
      dayNumber <= tripPlan.lengthInDays,
      let date = dayDate(dayNumber, tripStartDate: tripStartDate, calendar: calendar)
    else { return nil }

    let items = tripPlan.itineraryItems(
      forDay: dayNumber,
      travelTimes: travelTimes,
      effectiveModes: effectiveModes,
      now: now,
      tripStartDate: tripStartDate,
      stays: tripPlan.stays(coveringDay: dayNumber))
    let nextSelection = next(
      in: items,
      tripPlan: tripPlan,
      dayNumber: dayNumber,
      now: now,
      tripStartDate: tripStartDate,
      travelTimes: travelTimes,
      leaveByBuffer: leaveByBuffer)

    return Self(
      dayContext: dayContext(for: dayNumber, date: date, tripPlan: tripPlan),
      next: nextSelection?.value,
      remaining: remainingTimeline(
        items: items,
        now: now,
        dayNumber: dayNumber,
        tripStartDate: tripStartDate),
      tonight: tonight(forDay: dayNumber, in: tripPlan),
      tomorrow: tomorrow(
        after: dayNumber,
        tripPlan: tripPlan,
        tripStartDate: tripStartDate,
        travelTimes: travelTimes,
        effectiveModes: effectiveModes,
        calendar: calendar))
  }

  /// The 1-based trip day that `now` falls on, or `nil` when `now` is outside the
  /// trip's dated span. The Today surface uses this so live-day detection and the
  /// projection agree on the same calendar math.
  public static func tripDay(
    containing now: Date, tripStartDate: Date, in tripPlan: TripPlan
  ) -> Int? {
    guard let day = dayNumber(for: now, tripStartDate: tripStartDate, calendar: .current),
      day <= tripPlan.lengthInDays
    else { return nil }
    return day
  }

  /// The start of the calendar day for a 1-based trip day, or `nil` if the day is
  /// out of range. This is the instant Today renders when previewing a day that is
  /// not the live day.
  public static func startOfTripDay(_ dayNumber: Int, tripStartDate: Date) -> Date? {
    guard dayNumber >= 1 else { return nil }
    let calendar = Calendar.current
    guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: tripStartDate)
    else { return nil }
    return calendar.startOfDay(for: date)
  }

  private static func next(
    in items: [ItineraryItem],
    tripPlan: TripPlan,
    dayNumber: Int,
    now: Date,
    tripStartDate: Date,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    leaveByBuffer: TimeInterval
  ) -> (index: Int, value: Next)? {
    guard let index = items.firstIndex(where: { item in
      guard case let .stop(stop) = item else { return false }
      return isUpcoming(stop, now: now, tripStartDate: tripStartDate)
    }) else { return nil }
    let item = items[index]
    guard case let .stop(stop) = item else { return nil }
    let connector = items.compactMap { element -> TravelConnector? in
      guard case let .connector(connector) = element, connector.to.id == itemID(for: stop)
      else { return nil }
      return connector
    }.first
    return (
      index,
      Next(
        item: item,
        leaveBy: LeaveBy.resolve(
          schedule: stop.entry.schedule,
          connector: connector,
          travelTimes: travelTimes,
          tripStartDate: tripStartDate,
          buffer: leaveByBuffer),
        weatherAnchor: WeatherAnchor.resolve(
          for: stop,
          in: tripPlan,
          dayNumber: dayNumber,
          tripStartDate: tripStartDate)))
  }

  private static func remainingTimeline(
    items: [ItineraryItem], now: Date, dayNumber: Int, tripStartDate: Date
  ) -> [RemainingItem] {
    var earlierStopCount = 0
    var remaining: [RemainingItem] = []

    for index in items.indices {
      let item = items[index]
      if let nominalDate = rowNominalDate(
        for: item,
        preceding: index > items.startIndex ? items[index - 1] : nil,
        following: index + 1 < items.endIndex ? items[index + 1] : nil,
        dayNumber: dayNumber,
        tripStartDate: tripStartDate), nominalDate < now {
        if case .stop = item { earlierStopCount += 1 }
      } else {
        remaining.append(.item(item))
      }
    }

    let earlier: [RemainingItem] =
      earlierStopCount == 0 ? [] : [.earlierToday(count: earlierStopCount)]
    return earlier + remaining
  }

  /// Returns the event time represented by a timeline row. A connector belongs
  /// to the event at the edge it leaves; its neighboring row supplies that
  /// event's time because the connector itself carries only endpoints.
  private static func rowNominalDate(
    for item: ItineraryItem,
    preceding: ItineraryItem?,
    following: ItineraryItem?,
    dayNumber: Int,
    tripStartDate: Date
  ) -> Date? {
    switch item {
    case let .stop(stop):
      return nominalDate(for: stop.entry.schedule, tripStartDate: tripStartDate)
    case let .checkIn(stay):
      return boundaryDate(
        minutes: stay.stay.checkInSortMinutes,
        dayNumber: dayNumber,
        tripStartDate: tripStartDate)
    case let .checkOut(stay):
      return boundaryDate(
        minutes: stay.stay.checkOutSortMinutes,
        dayNumber: dayNumber,
        tripStartDate: tripStartDate)
    case let .calendarConstraint(constraint):
      return nominalDate(for: constraint.schedule, tripStartDate: tripStartDate)
    case .connector:
      return [preceding, following].compactMap { neighboringItem in
        neighboringItem.flatMap {
          rowNominalDate(
            for: $0,
            preceding: nil,
            following: nil,
            dayNumber: dayNumber,
            tripStartDate: tripStartDate)
        }
      }.first
    case .nowMarker, .homeBase: return nil
    }
  }

  private static func boundaryDate(
    minutes: Int, dayNumber: Int, tripStartDate: Date
  ) -> Date? {
    guard let start = dayStart(
      dayNumber: dayNumber, tripStartDate: tripStartDate, calendar: .current)
    else { return nil }
    return Calendar.current.date(byAdding: .minute, value: minutes, to: start)
  }

  private static func tonight(forDay dayNumber: Int, in tripPlan: TripPlan) -> Tonight? {
    guard let stay = tripPlan.stays(coveringDay: dayNumber).first(where: {
      $0.stay.nights.contains(dayNumber)
    }) else { return nil }
    let nights = stay.stay.nights
    guard let nightNumber = nights.firstIndex(of: dayNumber) else { return nil }
    return Tonight(
      stay: stay,
      nightNumber: nights.distance(from: nights.startIndex, to: nightNumber) + 1,
      totalNights: nights.count)
  }

  private static func dayNumber(
    for now: Date, tripStartDate: Date, calendar: Calendar
  ) -> Int? {
    let start = calendar.startOfDay(for: tripStartDate)
    let today = calendar.startOfDay(for: now)
    guard let offset = calendar.dateComponents([.day], from: start, to: today).day else { return nil }
    let dayNumber = offset + 1
    return dayNumber > 0 ? dayNumber : nil
  }

  private static func dayDate(
    _ dayNumber: Int, tripStartDate: Date, calendar: Calendar
  ) -> Date? {
    calendar.date(byAdding: .day, value: dayNumber - 1, to: tripStartDate)
  }

  private static func dayContext(
    for dayNumber: Int, date: Date, tripPlan: TripPlan
  ) -> DayContext {
    let stops = tripPlan.itinerary.first { $0.number == dayNumber }?.stops ?? []
    let stays = tripPlan.stays(coveringDay: dayNumber)
    let locality = tripPlan.region(forDay: dayNumber)?.name
      ?? stays.first { $0.stay.nights.contains(dayNumber) }?.idea?.regionName
      ?? stays.compactMap { $0.idea?.regionName }.first
      ?? stops.compactMap { $0.idea?.regionName }.first
    return DayContext(date: date, dayNumber: dayNumber, locality: locality)
  }

  private static func tomorrow(
    after dayNumber: Int,
    tripPlan: TripPlan,
    tripStartDate: Date,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    effectiveModes: [LegKey: TransportMode],
    calendar: Calendar
  ) -> Tomorrow? {
    let tomorrowNumber = dayNumber + 1
    guard tomorrowNumber <= tripPlan.lengthInDays,
      let date = dayDate(tomorrowNumber, tripStartDate: tripStartDate, calendar: calendar)
    else { return nil }
    let items = tripPlan.itineraryItems(
      forDay: tomorrowNumber,
      travelTimes: travelTimes,
      effectiveModes: effectiveModes,
      stays: tripPlan.stays(coveringDay: tomorrowNumber))
    let transfer = items.compactMap { item -> TravelConnector? in
      guard case let .connector(connector) = item, connector.kind == .betweenLodgings else {
        return nil
      }
      return connector
    }.first
    return Tomorrow(
      dayContext: dayContext(for: tomorrowNumber, date: date, tripPlan: tripPlan),
      transfer: transfer)
  }

  private static func itemID(for stop: ResolvedStop) -> String {
    "stop-\(stop.id)"
  }

  private static func isUpcoming(
    _ stop: ResolvedStop, now: Date, tripStartDate: Date
  ) -> Bool {
    guard let date = nominalDate(for: stop.entry.schedule, tripStartDate: tripStartDate) else {
      return false
    }
    return date >= now
  }
}

/// Honest travel guidance for the next stop: a clock only when the schedule
/// carries a clock, and otherwise an ETA without invented precision.
public enum LeaveBy: Equatable, Sendable {
  case clock(Date)
  case approximate(TravelTime)
  case awayBy(TravelTime)

  public static func resolve(
    schedule: Schedule,
    connector: TravelConnector?,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    tripStartDate: Date,
    buffer: TimeInterval
  ) -> Self? {
    guard let connector,
      connector.kind == .fromLodging || connector.kind == .betweenStops,
      let travelTime = travelTimes[connector.leg]?[connector.mode]
    else { return nil }

    switch schedule {
    case let .timed(dayNumber, start, _):
      guard let start = date(
        dayNumber: dayNumber, time: start, tripStartDate: tripStartDate, calendar: .current)
      else { return nil }
      return .clock(start.addingTimeInterval(-travelTime.seconds - buffer))
    case .daypart:
      return .approximate(travelTime)
    case .day, .unscheduled:
      return .awayBy(travelTime)
    }
  }
}

/// The raw location and time question for WeatherKit. This type intentionally
/// knows nothing about WeatherKit, `CLLocation`, or fetching a forecast.
public struct WeatherAnchor: Equatable, Sendable {
  public struct Coordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
      self.latitude = latitude
      self.longitude = longitude
    }
  }

  public enum TimeWindow: Equatable, Sendable {
    /// The real scheduled interval.
    case interval(DateInterval)
    /// The scheduled hour only; this intentionally does not invent a duration.
    case hour(Date)
    /// The schedule's named portion of its day.
    case daypart(dayStart: Date, DayPart)
    /// A broad daily forecast for Anytime and unscheduled items.
    case daily(Date)
  }

  public var coordinate: Coordinate
  public var timeWindow: TimeWindow
  public var isWeatherSensitive: Bool

  public init(coordinate: Coordinate, timeWindow: TimeWindow, isWeatherSensitive: Bool) {
    self.coordinate = coordinate
    self.timeWindow = timeWindow
    self.isWeatherSensitive = isWeatherSensitive
  }

  public static func resolve(
    for stop: ResolvedStop,
    in tripPlan: TripPlan,
    dayNumber: Int,
    tripStartDate: Date
  ) -> Self? {
    let sensitive = isWeatherSensitive(stop.idea?.kind)
    // NB: `coordinate(for:)` is overloaded (stop/stay/region). Resolving these
    // as separately-typed steps keeps the type-checker linear; folding them into
    // one `??` chain with unapplied overloads blows up type inference.
    let stopCoordinate: Coordinate? = coordinate(for: stop)
    let regionCoordinate: Coordinate? = coordinate(for: tripPlan.region(forDay: dayNumber))
    let stayCoordinate: Coordinate? =
      tripPlan.stays(coveringDay: dayNumber).compactMap { coordinate(for: $0) }.first
    let dayStopCoordinate: Coordinate? =
      (tripPlan.itinerary.first { $0.number == dayNumber }?.stops ?? [])
      .compactMap { coordinate(for: $0) }.first
    // A weather-sensitive stop defines the requested place. Other stops instead
    // use the day's region/base first, preserving the planned-presence fallback.
    let coordinate: Coordinate? =
      (sensitive ? stopCoordinate : nil)
      ?? regionCoordinate
      ?? stayCoordinate
      ?? stopCoordinate
      ?? dayStopCoordinate
    guard let coordinate,
      let timeWindow = timeWindow(for: stop.entry.schedule, tripStartDate: tripStartDate)
    else { return nil }
    return Self(coordinate: coordinate, timeWindow: timeWindow, isWeatherSensitive: sensitive)
  }

  private static func isWeatherSensitive(_ kind: IdeaKind?) -> Bool {
    switch kind {
    case .outdoorTrail, .beach, .park, .activity:
      true
    default:
      false
    }
  }

  private static func coordinate(for stop: ResolvedStop) -> Coordinate? {
    guard let latitude = stop.content.latitude, let longitude = stop.content.longitude else { return nil }
    return Coordinate(latitude: latitude, longitude: longitude)
  }

  private static func coordinate(for stay: ResolvedStay) -> Coordinate? {
    guard let latitude = stay.content.latitude, let longitude = stay.content.longitude else { return nil }
    return Coordinate(latitude: latitude, longitude: longitude)
  }

  private static func coordinate(for region: MapRegion?) -> Coordinate? {
    guard let region else { return nil }
    return Coordinate(latitude: region.centerLatitude, longitude: region.centerLongitude)
  }

  private static func timeWindow(for schedule: Schedule, tripStartDate: Date) -> TimeWindow? {
    switch schedule {
    case let .timed(dayNumber, start, end):
      guard let start = date(
        dayNumber: dayNumber, time: start, tripStartDate: tripStartDate, calendar: .current)
      else { return nil }
      guard let end else { return .hour(start) }
      guard let end = date(
        dayNumber: dayNumber, time: end, tripStartDate: tripStartDate, calendar: .current)
      else { return nil }
      return .interval(DateInterval(start: start, end: end))
    case let .daypart(dayNumber, part):
      guard let dayStart = dayStart(dayNumber: dayNumber, tripStartDate: tripStartDate, calendar: .current)
      else { return nil }
      return .daypart(dayStart: dayStart, part)
    case let .day(dayNumber):
      guard let dayStart = dayStart(dayNumber: dayNumber, tripStartDate: tripStartDate, calendar: .current)
      else { return nil }
      return .daily(dayStart)
    case .unscheduled:
      return .daily(Calendar.current.startOfDay(for: tripStartDate))
    }
  }
}

private func dayStart(dayNumber: Int, tripStartDate: Date, calendar: Calendar) -> Date? {
  guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: tripStartDate) else {
    return nil
  }
  return calendar.startOfDay(for: date)
}

private func date(
  dayNumber: Int, time: String, tripStartDate: Date, calendar: Calendar
) -> Date? {
  guard let dayStart = dayStart(dayNumber: dayNumber, tripStartDate: tripStartDate, calendar: calendar),
    let minutes = Schedule.minutes(from: time)
  else { return nil }
  return calendar.date(byAdding: .minute, value: minutes, to: dayStart)
}

private func nominalDate(for schedule: Schedule, tripStartDate: Date) -> Date? {
  let calendar = Calendar.current
  switch schedule {
  case .unscheduled:
    return nil
  case let .day(dayNumber):
    guard let start = dayStart(dayNumber: dayNumber, tripStartDate: tripStartDate, calendar: calendar)
    else { return nil }
    return calendar.date(bySettingHour: 23, minute: 59, second: 59, of: start)
  case let .daypart(dayNumber, part):
    guard let start = dayStart(dayNumber: dayNumber, tripStartDate: tripStartDate, calendar: calendar)
    else { return nil }
    return calendar.date(bySettingHour: part.sortHour, minute: 0, second: 0, of: start)
  case let .timed(dayNumber, start, _):
    return date(dayNumber: dayNumber, time: start, tripStartDate: tripStartDate, calendar: calendar)
  }
}
