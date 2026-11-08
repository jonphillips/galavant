import Foundation

public struct GuideTripLens: Equatable, Sendable {
  public struct TripChoice: Identifiable, Equatable, Sendable {
    public var id: Trip.ID
    public var name: String

    public init(id: Trip.ID, name: String) {
      self.id = id
      self.name = name
    }
  }

  public struct SlotStop: Identifiable, Equatable, Sendable {
    public var id: TripIdea.ID
    public var ideaID: Idea.ID?
    public var title: String
    public var isFreeform: Bool
    public var isBooked: Bool
    public var optionCount: Int
  }

  public enum MealCell: Equatable, Sendable {
    case open
    case filled([SlotStop])
  }

  public struct MealDay: Identifiable, Equatable, Sendable {
    public var day: Int
    public var weekday: Weekday?
    public var date: Date?
    public var summary: String?
    public var lunch: MealCell
    public var dinner: MealCell
    public var alsoThatDay: [SlotStop]
    public var id: Int { day }
  }

  public enum NightRun: Equatable, Sendable {
    case stay(stayID: TripStay.ID, ideaID: Idea.ID?, title: String, isBooked: Bool, nights: ClosedRange<Int>)
    case open(nights: ClosedRange<Int>)
  }

  public enum Body: Equatable, Sendable {
    case meals([MealDay])
    case nights([NightRun])
  }

  public enum Badge: Equatable, Sendable {
    case meal(day: Int, Meal, ringActive: Bool?)
    case nights(ClosedRange<Int>)
    case onTrip
  }

  public var trip: TripChoice
  public var otherTrips: [TripChoice]
  public var regionDays: [Int]
  public var body: Body
  public var badges: [Idea.ID: Badge]
  public var weekdaysByDay: [Int: Weekday]
  public var regionName: String

  /// Straight-line distance, in kilometers, using the same Earth-radius model as
  /// `MapFraming.distanceInMeters` (6,371 km). This is a display aid, not a route.
  public static func distanceInKilometers(from origin: TripCoordinate, to destination: TripCoordinate) -> Double {
    MapFraming.distanceInMeters(
      latitude1: origin.latitude, longitude1: origin.longitude,
      latitude2: destination.latitude, longitude2: destination.longitude) / 1_000
  }

  /// Straight-line distance from an idea to the accommodation that owns `day`.
  /// The result stays unformatted so the presentation can choose locale and units.
  public static func distanceFromStay(
    day: Int, ideaID: Idea.ID, plan: TripPlan, stays: [TripStay], ideas: [Idea]
  ) -> (distance: Measurement<UnitLength>, hotelName: String)? {
    guard let stayID = plan.stayID(owningDay: day),
      let stay = stays.first(where: { $0.id == stayID }),
      let hotelID = stay.ideaID,
      let hotel = ideas.first(where: { $0.id == hotelID }),
      let hotelLatitude = hotel.latitude, let hotelLongitude = hotel.longitude,
      let idea = ideas.first(where: { $0.id == ideaID }),
      let latitude = idea.latitude, let longitude = idea.longitude
    else { return nil }
    let meters = MapFraming.distanceInMeters(
      latitude1: latitude, longitude1: longitude,
      latitude2: hotelLatitude, longitude2: hotelLongitude)
    return (Measurement(value: meters, unit: UnitLength.meters), hotel.name)
  }

  public var heading: String {
    switch body {
    case .meals:
      if regionDays.count == 1 { return "Day \(regionDays[0]) in \(regionName)" }
      return "\(regionDays.count) days in \(regionName)"
    case let .nights(runs):
      let ranges = runs.compactMap { run -> ClosedRange<Int>? in
        switch run {
        case let .open(nights): nights
        case let .stay(_, _, _, _, nights): nights
        }
      }
      guard !ranges.isEmpty else { return "Nights in \(regionName)" }
      let labels = ranges.map { range in
        range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound)–\(range.upperBound)"
      }
      let singular = ranges.count == 1 && ranges[0].lowerBound == ranges[0].upperBound
      return "Night\(singular ? "" : "s") \(labels.joined(separator: ", ")) in \(regionName)"
    }
  }

  public func badgeLabel(for ideaID: Idea.ID) -> String? {
    badges[ideaID].map { $0.label(in: self) }
  }

  public static func candidates(
    region: MapRegion, trips: [Trip], dayRegions: [TripDayRegion], now: Date, calendar: Calendar
  ) -> [TripChoice] {
    let matchingIDs = Set(dayRegions.filter { $0.regionID == region.id }.map(\.tripID))
    let matching = trips.filter { matchingIDs.contains($0.id) }
    let sections = Trip.sectioned(matching, now: now, calendar: calendar)
    return (sections.dated + sections.targeted + sections.someday).map { TripChoice(id: $0.id, name: $0.name) }
  }

  public static func chosenTripID(
    chipPick: Trip.ID?, preferred: Trip.ID?, candidates: [TripChoice]
  ) -> Trip.ID? {
    if let chipPick, candidates.contains(where: { $0.id == chipPick }) { return chipPick }
    if let preferred, candidates.contains(where: { $0.id == preferred }) { return preferred }
    return candidates.first?.id
  }

  public init(
    trip: Trip, candidates: [TripChoice], region: MapRegion, category: GuideCategory,
    plan: TripPlan, dayNotes: [TripDayNote] = [], calendar: Calendar
  ) {
    self.trip = TripChoice(id: trip.id, name: trip.name)
    otherTrips = candidates.filter { $0.id != trip.id }
    regionDays = plan.dayRegions.filter { $0.regionID == region.id }
      .map(\.dayNumber).filter { $0 >= 1 && $0 <= trip.lengthInDays }.sorted()
    regionName = region.name
    let tripDays = trip.lengthInDays > 0 ? Array(1...trip.lengthInDays) : []
    weekdaysByDay = Dictionary(tripDays.compactMap { day in
      trip.date(forDay: day).flatMap { date in Weekday.from(date, calendar: calendar).map { (day, $0) } }
    }, uniquingKeysWith: { first, _ in first })

    let nights = regionDays.filter { $0 < trip.lengthInDays }
    let stayGroups = plan.stayDayGroups()
    let staysByID = Dictionary(stayGroups.compactMap { group in group.stay.map { ($0.id, $0) } }, uniquingKeysWith: { first, _ in first })
    let stayIDByDay = Dictionary(stayGroups.flatMap { group in group.days.map { ($0, group.stay?.id) } }, uniquingKeysWith: { first, _ in first })
    var projection = Self.projectStops(
      plan: plan, regionDays: Set(regionDays), rings: plan.resolvedAlternativeRings)
    let nightRuns = Self.nightRuns(nights: nights, stayIDByDay: stayIDByDay, staysByID: staysByID)
    for run in nightRuns {
      guard case let .stay(_, ideaID, _, _, range) = run, let ideaID,
            projection.badges[ideaID] == nil else { continue }
      projection.badges[ideaID] = .nights(range)
    }

    if category == .dining {
      body = .meals(regionDays.map { day in
        let date = trip.date(forDay: day)
        let values = projection.slots[day] ?? [:]
        return MealDay(
          day: day, weekday: date.flatMap { Weekday.from($0, calendar: calendar) }, date: date,
          summary: dayNotes.first { $0.tripID == trip.id && $0.dayNumber == day }?.note,
          lunch: values[.lunch].map(MealCell.filled) ?? .open,
          dinner: values[.dinner].map(MealCell.filled) ?? .open,
          alsoThatDay: projection.anytime[day] ?? [])
      })
    } else {
      body = .nights(nightRuns)
    }

    for entry in plan.entries where entry.status != .declined && entry.status != .done && entry.status != .skipped
      && entry.completedAt == nil && entry.skippedAt == nil {
      guard let ideaID = entry.ideaID, projection.badges[ideaID] == nil else { continue }
      projection.badges[ideaID] = .onTrip
    }
    badges = projection.badges
  }

  private static func projectStops(
    plan: TripPlan, regionDays: Set<Int>, rings: [UUID: ResolvedAlternativeRing]
  ) -> StopProjection {
    var projection = StopProjection()
    for day in plan.itinerary where regionDays.contains(day.number) {
      for stop in day.stops {
        let ring = stop.entry.alternativeGroupID.flatMap { rings[$0] }
        let activeID = ring?.activeMember.id
        let slotStop = SlotStop(id: stop.id, ideaID: stop.idea?.id, title: stop.content.title,
          isFreeform: stop.idea == nil, isBooked: stop.entry.bookingStatus == .booked,
          optionCount: ring?.members.count ?? 1)
        if case let .day(dayNumber) = stop.entry.schedule {
          if let idea = stop.idea, IdeaKindGroup(kind: idea.kind) == .food {
            projection.anytime[dayNumber, default: []].append(slotStop)
          }
          continue
        }
        guard let meal = Self.meal(for: stop.entry.schedule, day: day.number) else { continue }
        for member in ring?.members ?? [stop] where Self.isActiveForBadge(member.entry) {
          guard let ideaID = member.idea?.id else { continue }
          projection.badges[ideaID] = .meal(day: day.number, meal, ringActive: ring == nil ? nil : member.id == activeID)
        }
        if ring == nil || activeID == stop.id {
          projection.slots[day.number, default: [:]][meal, default: []].append(slotStop)
        }
      }
    }
    return projection
  }

  private static func meal(for schedule: Schedule, day: Int) -> Meal? {
    switch schedule {
    case let .daypart(number, part) where number == day:
      return part == .lunch ? .lunch : part == .dinner ? .dinner : nil
    case let .timed(number, start, _) where number == day:
      guard let minute = Schedule.minutes(from: start) else { return nil }
      let meal = Meal.forClock(minute: minute)
      return meal == .lunch || meal == .dinner ? meal : nil
    default: return nil
    }
  }

  private static func isActiveForBadge(_ entry: TripIdea) -> Bool {
    entry.status != .done && entry.status != .skipped && entry.completedAt == nil && entry.skippedAt == nil
  }

  private static func nightRuns(
    nights: [Int], stayIDByDay: [Int: TripStay.ID?], staysByID: [TripStay.ID: ResolvedStay]
  ) -> [NightRun] {
    var runs: [NightRun] = []
    for day in nights {
      let owner = stayIDByDay[day] ?? nil
      guard let last = runs.last else {
        runs.append(run(owner: owner, day: day, staysByID: staysByID))
        continue
      }
      switch last {
      case let .stay(id, _, _, _, range) where id == owner && range.upperBound + 1 == day:
        if let stay = staysByID[id] {
          runs[runs.count - 1] = .stay(stayID: id, ideaID: stay.idea?.id, title: stay.content.title,
            isBooked: stay.stay.bookingStatus == .booked, nights: range.lowerBound...day)
        }
      case let .open(range) where owner == nil && range.upperBound + 1 == day:
        runs[runs.count - 1] = .open(nights: range.lowerBound...day)
      default: runs.append(run(owner: owner, day: day, staysByID: staysByID))
      }
    }
    return runs
  }

  private static func run(owner: TripStay.ID?, day: Int, staysByID: [TripStay.ID: ResolvedStay]) -> NightRun {
    guard let owner, let stay = staysByID[owner] else { return .open(nights: day...day) }
    return .stay(stayID: owner, ideaID: stay.idea?.id, title: stay.content.title,
      isBooked: stay.stay.bookingStatus == .booked, nights: day...day)
  }
}

private struct StopProjection {
  var slots: [Int: [Meal: [GuideTripLens.SlotStop]]] = [:]
  var anytime: [Int: [GuideTripLens.SlotStop]] = [:]
  var badges: [Idea.ID: GuideTripLens.Badge] = [:]
}

public extension GuideTripLens.Badge {
  func label(in lens: GuideTripLens) -> String {
    switch self {
    case let .meal(day, meal, ringActive):
      let prefix: String
      if let weekday = lens.weekdaysByDay[day] {
        prefix = "\(weekday.shortLabel) \(meal.label.lowercased())"
      } else {
        prefix = "Day \(day) \(meal.label.lowercased())"
      }
      return prefix + (ringActive == true ? " · active" : "")
    case let .nights(range): return range.lowerBound == range.upperBound ? "Night \(range.lowerBound)" : "Nights \(range.lowerBound)–\(range.upperBound)"
    case .onTrip: return "On trip"
    }
  }
}
