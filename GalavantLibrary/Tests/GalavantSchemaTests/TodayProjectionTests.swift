import Foundation
import GalavantSchema
import Testing

@Suite struct TodayProjectionTests {
  private let tripID = UUID()

  private var startDate: Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 15))!
  }

  private func date(day: Int = 1, hour: Int, minute: Int = 0) -> Date {
    let dayDate = Calendar.current.date(byAdding: .day, value: day - 1, to: startDate)!
    return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: dayDate)!
  }

  private func idea(
    _ id: UUID,
    name: String,
    kind: IdeaKind? = nil,
    region: String? = nil,
    latitude: Double? = 1,
    longitude: Double? = 2
  ) -> Idea {
    Idea(
      id: id,
      name: name,
      kind: kind,
      regionName: region,
      latitude: latitude,
      longitude: longitude)
  }

  private func stop(
    _ ideaID: UUID,
    schedule: Schedule,
    rank: Int = 0,
    completedAt: Date? = nil,
    skippedAt: Date? = nil
  ) -> TripIdea {
    var entry = TripIdea(
      id: UUID(),
      tripID: tripID,
      ideaID: ideaID,
      status: .scheduled,
      dayRank: Double(rank),
      completedAt: completedAt,
      skippedAt: skippedAt)
    entry.apply(schedule)
    return entry
  }

  private func stay(_ ideaID: UUID, checkIn: Int, checkOut: Int) -> TripStay {
    TripStay(id: UUID(), tripID: tripID, ideaID: ideaID, checkInDay: checkIn, checkOutDay: checkOut)
  }

  private func plan(
    entries: [TripIdea],
    ideas: [Idea],
    length: Int = 3,
    stays: [TripStay] = [],
    regions: [MapRegion] = [],
    assignments: [TripDayRegion] = []
  ) -> TripPlan {
    TripPlan(
      entries: entries,
      ideasByID: Dictionary(uniqueKeysWithValues: ideas.map { ($0.id, $0) }),
      lengthInDays: length,
      tripStays: stays,
      dayRegions: assignments,
      regionsByID: Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) }))
  }

  private func projection(
    _ plan: TripPlan,
    now: Date,
    travelTimes: [LegKey: [TransportMode: TravelTime]] = [:]
  ) -> TodayProjection {
    TodayProjection.resolve(
      from: plan,
      now: now,
      tripStartDate: startDate,
      travelTimes: travelTimes,
      leaveByBuffer: 0)!
  }

  @Test func tripDayUsesTheTripCalendarSpan() {
    let tripPlan = plan(entries: [], ideas: [], length: 3)

    #expect(TodayProjection.tripDay(containing: date(day: 2, hour: 10), tripStartDate: startDate, in: tripPlan) == 2)
    #expect(TodayProjection.tripDay(containing: date(day: 1, hour: 0).addingTimeInterval(-1), tripStartDate: startDate, in: tripPlan) == nil)
    #expect(TodayProjection.tripDay(containing: date(day: 4, hour: 0), tripStartDate: startDate, in: tripPlan) == nil)
  }

  @Test func startOfTripDayResolvesCalendarMidnights() {
    #expect(
      TodayProjection.startOfTripDay(1, tripStartDate: startDate)
        == Calendar.current.startOfDay(for: startDate))
    #expect(
      TodayProjection.startOfTripDay(2, tripStartDate: startDate)
        == Calendar.current.startOfDay(for: date(day: 2, hour: 12)))
    #expect(TodayProjection.startOfTripDay(0, tripStartDate: startDate) == nil)
  }

  @Test func startOfDayProjectionKeepsTheWholeDayAhead() {
    let (morningID, eveningID) = (UUID(), UUID())
    let tripPlan = plan(
      entries: [
        stop(morningID, schedule: .timed(1, start: "09:00", end: nil)),
        stop(eveningID, schedule: .timed(1, start: "18:00", end: nil), rank: 1),
      ],
      ideas: [idea(morningID, name: "Breakfast"), idea(eveningID, name: "Dinner")])

    let preview = projection(tripPlan, now: date(day: 1, hour: 0))

    #expect(stopID(in: preview.next?.item) == morningID)
    #expect(!preview.remaining.contains { item in
      if case .done = item { return true }
      return false
    })
    #expect(preview.progress == .init(done: 0, total: 2))
    #expect(preview.dayContext.dayNumber == 1)
  }

  @Test func nextSelectionUsesPendingUpcomingAndKeepsPendingPastVisible() {
    let (morningID, noonID, eveningID) = (UUID(), UUID(), UUID())
    let tripPlan = plan(
      entries: [
        stop(morningID, schedule: .timed(1, start: "09:00", end: nil)),
        stop(noonID, schedule: .timed(1, start: "12:00", end: nil), rank: 1),
        stop(eveningID, schedule: .timed(1, start: "18:00", end: nil), rank: 2),
      ],
      ideas: [
        idea(morningID, name: "Breakfast"),
        idea(noonID, name: "Museum"),
        idea(eveningID, name: "Dinner"),
      ])

    let early = projection(tripPlan, now: date(hour: 8))
    let exactStart = projection(tripPlan, now: date(hour: 9))
    let midday = projection(tripPlan, now: date(hour: 13))
    let late = projection(tripPlan, now: date(hour: 20))

    #expect(stopID(in: early.next?.item) == morningID)
    // Today means at-or-after now: a stop beginning at the exact clock is still next.
    #expect(stopID(in: exactStart.next?.item) == morningID)
    #expect(stopID(in: midday.next?.item) == eveningID)
    #expect(late.next == nil)
    #expect(midday.remaining.contains { item in
      if case let .item(.stop(stop)) = item { return stop.idea?.id == morningID }
      return false
    })
    #expect(late.remaining.contains { item in
      if case .item(.stop) = item { return true }
      return false
    })
    #expect(!late.remaining.contains { item in
      if case .done = item { return true }
      return false
    })
    #expect(early.remaining.contains { item in
      if case .item(.connector) = item { return true }
      return false
    })
  }

  @Test func anytimeCompletionAdvancesNextAndProgressExcludesSkippedStops() {
    let (firstID, secondID, thirdID) = (UUID(), UUID(), UUID())
    let completedAt = date(hour: 10)
    let tripPlan = plan(
      entries: [
        stop(firstID, schedule: .day(1), rank: 0, completedAt: completedAt),
        stop(secondID, schedule: .day(1), rank: 1, skippedAt: completedAt),
        stop(thirdID, schedule: .day(1), rank: 2),
      ],
      ideas: [
        idea(firstID, name: "First"),
        idea(secondID, name: "Second"),
        idea(thirdID, name: "Third"),
      ])

    let today = projection(tripPlan, now: date(hour: 11))

    #expect(stopID(in: today.next?.item) == thirdID)
    #expect(today.progress == .init(done: 1, total: 2))
    #expect(today.remaining.first == .done(count: 1))
    #expect(today.remaining.dropFirst().first == .skipped(count: 1))
    #expect(today.doneStops.map(\.entry.ideaID) == [firstID])
    #expect(today.skippedStops.map(\.entry.ideaID) == [secondID])
  }

  @Test func pendingStopWhoseTimePassedStaysInRemaining() {
    let id = UUID()
    let tripPlan = plan(
      entries: [stop(id, schedule: .timed(1, start: "09:00", end: nil))],
      ideas: [idea(id, name: "Morning stop")])

    let today = projection(tripPlan, now: date(hour: 13))

    #expect(today.next == nil)
    #expect(today.remaining.contains { item in
      if case let .item(.stop(stop)) = item { return stop.id == tripPlan.entries[0].id }
      return false
    })
    #expect(!today.remaining.contains { item in
      if case .done = item { return true }
      return false
    })
  }

  @Test func transferDayKeepsFutureStayBoundariesAndTransferInRemaining() {
    let (firstHotelID, secondHotelID, dinnerID) = (UUID(), UUID(), UUID())
    let firstHotel = TripStay(
      id: UUID(),
      tripID: tripID,
      ideaID: firstHotelID,
      checkInDay: 1,
      checkOutDay: 3,
      checkOutTime: "10:00")
    let secondHotel = TripStay(
      id: UUID(),
      tripID: tripID,
      ideaID: secondHotelID,
      checkInDay: 3,
      checkOutDay: 4,
      checkInTime: "18:00")
    let dinner = stop(dinnerID, schedule: .timed(3, start: "20:00", end: nil))
    let tripPlan = plan(
      entries: [dinner],
      ideas: [
        idea(firstHotelID, name: "First Hotel", latitude: 1, longitude: 2),
        idea(secondHotelID, name: "Second Hotel", latitude: 3, longitude: 4),
        idea(dinnerID, name: "Dinner", latitude: 5, longitude: 6),
      ],
      length: 4,
      stays: [firstHotel, secondHotel])
    let transferLeg = LegKey(fromLat: 1, fromLon: 2, toLat: 3, toLon: 4)
    let transferTime = TravelTime(seconds: 60, meters: 100)
    let travelTimes: [LegKey: [TransportMode: TravelTime]] = [
      transferLeg: [.walking: transferTime]
    ]

    for now in [date(day: 3, hour: 0), date(day: 3, hour: 9)] {
      let today = projection(tripPlan, now: now, travelTimes: travelTimes)

      #expect(today.remaining.contains { item in
        if case .item(.checkOut) = item { return true }
        return false
      })
      #expect(today.remaining.contains { item in
        if case let .item(.connector(connector)) = item {
          return connector.kind == .betweenLodgings && connector.travelTime == transferTime
        }
        return false
      })
      #expect(today.remaining.contains { item in
        if case .item(.checkIn) = item { return true }
        return false
      })
      #expect(!today.remaining.contains { item in
      if case .done = item { return true }
        return false
      })
    }
  }

  @Test func leaveByUsesTheScheduleHonestyLadder() {
    let leg = LegKey(fromLat: 1, fromLon: 2, toLat: 3, toLon: 4)
    let travelTime = TravelTime(seconds: 20 * 60, meters: 1_000)
    let connector = TravelConnector(
      from: TravelEndpoint(id: "hotel", title: "Hotel", latitude: 1, longitude: 2),
      to: TravelEndpoint(id: "stop", title: "Museum", latitude: 3, longitude: 4),
      leg: leg,
      mode: .driving,
      travelTime: nil,
      kind: .fromLodging)
    let travelTimes: [LegKey: [TransportMode: TravelTime]] = [leg: [.driving: travelTime]]

    let clock = LeaveBy.resolve(
      schedule: .timed(1, start: "10:00", end: nil),
      connector: connector,
      travelTimes: travelTimes,
      tripStartDate: startDate,
      buffer: 5 * 60)
    let approximate = LeaveBy.resolve(
      schedule: .daypart(1, .morning),
      connector: connector,
      travelTimes: travelTimes,
      tripStartDate: startDate,
      buffer: 0)
    let anytime = LeaveBy.resolve(
      schedule: .day(1),
      connector: connector,
      travelTimes: travelTimes,
      tripStartDate: startDate,
      buffer: 0)
    let unscheduled = LeaveBy.resolve(
      schedule: .unscheduled,
      connector: connector,
      travelTimes: travelTimes,
      tripStartDate: startDate,
      buffer: 0)

    #expect(clock == .clock(date(hour: 9, minute: 35)))
    #expect(approximate == .approximate(travelTime, mode: .driving))
    #expect(anytime == .awayBy(travelTime, mode: .driving))
    #expect(unscheduled == .awayBy(travelTime, mode: .driving))

    let walkingConnector = TravelConnector(
      from: connector.from,
      to: connector.to,
      leg: leg,
      mode: .walking,
      travelTime: nil,
      kind: .fromLodging)
    let walking = LeaveBy.resolve(
      schedule: .day(1),
      connector: walkingConnector,
      travelTimes: [leg: [.walking: travelTime]],
      tripStartDate: startDate,
      buffer: 0)

    #expect(walking == .awayBy(travelTime, mode: .walking))
  }

  @Test func weatherAnchorFollowsTheCoordinateLadder() {
    let sensitiveID = UUID()
    let fallbackID = UUID()
    let stayID = UUID()
    let region = MapRegion(
      id: UUID(), name: "Coast", centerLatitude: 10, centerLongitude: 20,
      latitudeDelta: 1, longitudeDelta: 1)
    let sensitive = stop(sensitiveID, schedule: .timed(1, start: "09:00", end: "11:00"))
    let nonSensitive = stop(fallbackID, schedule: .day(1))
    let hotel = stay(stayID, checkIn: 1, checkOut: 2)

    let sensitivePlan = plan(
      entries: [sensitive, nonSensitive],
      ideas: [
        idea(sensitiveID, name: "Trail", kind: .outdoorTrail, latitude: 1, longitude: 2),
        idea(fallbackID, name: "Cafe", latitude: 50, longitude: 60),
        idea(stayID, name: "Hotel", latitude: 30, longitude: 40),
      ],
      stays: [hotel],
      regions: [region],
      assignments: [TripDayRegion(id: UUID(), tripID: tripID, dayNumber: 1, regionID: region.id)])
    let sensitiveStop = sensitivePlan.itinerary[0].stops[0]
    let sensitiveAnchor = WeatherAnchor.resolve(
      for: sensitiveStop, in: sensitivePlan, dayNumber: 1, tripStartDate: startDate)
    #expect(sensitiveAnchor?.coordinate == .init(latitude: 1, longitude: 2))
    #expect(sensitiveAnchor?.isWeatherSensitive == true)

    let regionPlan = plan(
      entries: [nonSensitive],
      ideas: [idea(fallbackID, name: "Cafe", latitude: 50, longitude: 60)],
      regions: [region],
      assignments: [TripDayRegion(id: UUID(), tripID: tripID, dayNumber: 1, regionID: region.id)])
    #expect(anchorCoordinate(for: regionPlan, stop: 0) == .init(latitude: 10, longitude: 20))

    let stayPlan = plan(
      entries: [nonSensitive],
      ideas: [
        idea(fallbackID, name: "Cafe", latitude: nil, longitude: nil),
        idea(stayID, name: "Hotel", latitude: 30, longitude: 40),
      ],
      stays: [hotel])
    #expect(anchorCoordinate(for: stayPlan, stop: 0) == .init(latitude: 30, longitude: 40))

    let geographyPlan = plan(
      entries: [
        stop(fallbackID, schedule: .day(1)),
        stop(sensitiveID, schedule: .day(1), rank: 1),
      ],
      ideas: [
        idea(fallbackID, name: "Unlocated", latitude: nil, longitude: nil),
        idea(sensitiveID, name: "Elsewhere", kind: .food, latitude: 50, longitude: 60),
      ])
    #expect(anchorCoordinate(for: geographyPlan, stop: 0) == .init(latitude: 50, longitude: 60))

    let omittedPlan = plan(
      entries: [nonSensitive],
      ideas: [idea(fallbackID, name: "Unlocated", latitude: nil, longitude: nil)])
    #expect(anchorCoordinate(for: omittedPlan, stop: 0) == nil)
  }

  @Test func weatherAnchorMapsEveryScheduleToItsTimeWindow() {
    let id = UUID()
    let schedules: [Schedule] = [
      .timed(1, start: "09:00", end: "11:00"),
      .timed(1, start: "12:00", end: nil),
      .daypart(1, .afternoon),
      .day(1),
      .unscheduled,
    ]

    let anchors = schedules.compactMap { schedule -> WeatherAnchor? in
      let tripPlan = plan(entries: [stop(id, schedule: schedule)], ideas: [idea(id, name: "Place")])
      return WeatherAnchor.resolve(
        for: tripPlan.itinerary.first?.stops.first ?? ResolvedStop(
          entry: stop(id, schedule: schedule), content: .idea(idea(id, name: "Place"))),
        in: tripPlan,
        dayNumber: 1,
        tripStartDate: startDate)
    }

    #expect(anchors.count == schedules.count)
    if case let .interval(interval) = anchors[0].timeWindow {
      #expect(interval.start == date(hour: 9))
      #expect(interval.end == date(hour: 11))
    } else { Issue.record("timed interval should preserve its real end") }
    #expect(anchors[1].timeWindow == .hour(date(hour: 12)))
    #expect(anchors[2].timeWindow == .daypart(dayStart: startDate, .afternoon))
    #expect(anchors[3].timeWindow == .daily(startDate))
    #expect(anchors[4].timeWindow == .daily(startDate))
  }

  @Test func tonightAndTomorrowCarryTheStayAndLodgingTransferOrientation() {
    let (firstHotelID, secondHotelID) = (UUID(), UUID())
    let firstHotel = stay(firstHotelID, checkIn: 1, checkOut: 2)
    let secondHotel = stay(secondHotelID, checkIn: 2, checkOut: 4)
    let tripPlan = plan(
      entries: [],
      ideas: [
        idea(firstHotelID, name: "First Hotel", region: "Old Town", latitude: 1, longitude: 2),
        idea(secondHotelID, name: "Second Hotel", region: "New Town", latitude: 3, longitude: 4),
      ],
      stays: [firstHotel, secondHotel])
    let leg = LegKey(fromLat: 1, fromLon: 2, toLat: 3, toLon: 4)
    let today = projection(
      tripPlan,
      now: date(hour: 10),
      travelTimes: [leg: [.walking: TravelTime(seconds: 600, meters: 500)]])

    #expect(today.tonight?.nightNumber == 1)
    #expect(today.tonight?.totalNights == 1)
    #expect(today.tomorrow?.dayContext.locality == "New Town")
    #expect(today.tomorrow?.transfer?.kind == .betweenLodgings)
    #expect(today.tomorrow?.transfer?.travelTime == TravelTime(seconds: 600, meters: 500))
  }

  @Test func multiDayProjectionUsesTheCorrectDayAndNightOrdinal() {
    let (hotelID, lunchID) = (UUID(), UUID())
    let tripPlan = plan(
      entries: [stop(lunchID, schedule: .timed(2, start: "12:00", end: nil))],
      ideas: [
        idea(hotelID, name: "Hotel", region: "Harbor"),
        idea(lunchID, name: "Lunch", region: "Harbor"),
      ],
      length: 3,
      stays: [stay(hotelID, checkIn: 1, checkOut: 4)])
    let today = projection(tripPlan, now: date(day: 2, hour: 9))

    #expect(today.dayContext.dayNumber == 2)
    #expect(stopID(in: today.next?.item) == lunchID)
    #expect(today.tonight?.nightNumber == 2)
    #expect(today.tonight?.totalNights == 3)
  }

  @Test func lastTripDayHasNoTomorrowOrientation() {
    let id = UUID()
    let tripPlan = plan(
      entries: [stop(id, schedule: .timed(2, start: "12:00", end: nil))],
      ideas: [idea(id, name: "Final lunch")],
      length: 2)
    let today = projection(tripPlan, now: date(day: 2, hour: 9))

    #expect(today.dayContext.dayNumber == 2)
    #expect(today.tomorrow == nil)
  }

  @Test func explicitlyLeadingAnytimeStopStaysAheadOfALaterTimedStop() {
    let (anytimeID, timedID) = (UUID(), UUID())
    let tripPlan = plan(
      entries: [
        stop(anytimeID, schedule: .day(1), rank: -1),
        stop(timedID, schedule: .timed(1, start: "10:00", end: nil), rank: 1),
      ],
      ideas: [idea(anytimeID, name: "Wander"), idea(timedID, name: "Museum")])

    #expect(stopID(in: projection(tripPlan, now: date(hour: 8)).next?.item) == anytimeID)
  }

  @Test func projectionIsCompleteWhenEveryWeatherFieldIsNil() {
    let id = UUID()
    let tripPlan = plan(
      entries: [stop(id, schedule: .timed(1, start: "12:00", end: nil))],
      ideas: [idea(id, name: "Unlocated lunch", latitude: nil, longitude: nil)])
    let today = projection(tripPlan, now: date(hour: 9))

    #expect(today.dayContext.dayNumber == 1)
    #expect(today.next != nil)
    #expect(today.next?.weatherAnchor == nil)
    #expect(today.remaining.isEmpty == false)
  }

  // MARK: - Stay boundaries and constraints are real events (dogfood, Slice F)

  /// The dogfood screenshot's exact shape: a done morning stop, a pending Anytime
  /// lunch anchored to it, and a 15:00 check-in — read at 13:45, between them.
  private func dogfoodDay(
    lunchSchedule: Schedule = .day(2),
    checkInTime: String? = "15:00"
  ) -> (plan: TripPlan, travelTimes: [LegKey: [TransportMode: TravelTime]], lunchID: UUID, stayID: UUID) {
    let (morningID, lunchID, hotelID) = (UUID(), UUID(), UUID())
    let hotel = TripStay(
      id: UUID(),
      tripID: tripID,
      ideaID: hotelID,
      checkInDay: 2,
      checkOutDay: 3,
      checkInTime: checkInTime)
    let tripPlan = plan(
      entries: [
        stop(morningID, schedule: .timed(2, start: "09:00", end: nil), completedAt: date(day: 2, hour: 9)),
        stop(lunchID, schedule: lunchSchedule, rank: 1),
      ],
      ideas: [
        idea(morningID, name: "Morning walk", latitude: 1, longitude: 2),
        idea(lunchID, name: "St Maddalena", latitude: 3, longitude: 4),
        idea(hotelID, name: "Forestis", latitude: 5, longitude: 6),
      ],
      stays: [hotel])
    let toLodging = LegKey(fromLat: 3, fromLon: 4, toLat: 5, toLon: 6)
    return (tripPlan, [toLodging: [.walking: TravelTime(seconds: 15 * 60, meters: 8_000)]], lunchID, hotel.id)
  }

  private func remainingItems(_ projection: TodayProjection) -> [ItineraryItem] {
    projection.remaining.compactMap {
      guard case let .item(item) = $0 else { return nil }
      return item
    }
  }

  @Test func aFutureCheckInIsNextWhenNoStopIsStillAhead() {
    let day = dogfoodDay()

    let today = projection(day.plan, now: date(day: 2, hour: 13, minute: 45), travelTimes: day.travelTimes)

    guard case let .checkIn(stay) = today.next?.item else {
      Issue.record("a 15:00 check-in 75 minutes away is what happens next, not nothing")
      return
    }
    #expect(stay.id == day.stayID)
    // A check-in you drive 15 minutes to is a departure time like any other.
    #expect(today.next?.leaveBy == .clock(date(day: 2, hour: 14, minute: 45)))
  }

  @Test func anUntimedCheckInIsNextWithoutInventingAClock() {
    let day = dogfoodDay(checkInTime: nil)

    let today = projection(day.plan, now: date(day: 2, hour: 13, minute: 45), travelTimes: day.travelTimes)

    guard case .checkIn = today.next?.item else {
      Issue.record("an untimed check-in is still the next event of the day")
      return
    }
    #expect(today.next?.leaveBy == .awayBy(TravelTime(seconds: 15 * 60, meters: 8_000), mode: .walking))
  }

  @Test func nowMarkerSitsAboveAFutureCheckInRatherThanBelowIt() {
    let day = dogfoodDay()

    let today = projection(day.plan, now: date(day: 2, hour: 13, minute: 45), travelTimes: day.travelTimes)

    let items = remainingItems(today)
    let markerIndex = items.firstIndex { if case .nowMarker = $0 { return true } else { return false } }
    let checkInIndex = items.firstIndex { if case .checkIn = $0 { return true } else { return false } }
    let lunchIndex = items.firstIndex { item in
      guard case let .stop(stop) = item else { return false }
      return stop.idea?.id == day.lunchID
    }
    guard let markerIndex, let checkInIndex, let lunchIndex else {
      Issue.record("expected the lunch, the marker and the check-in on the timeline")
      return
    }
    #expect(lunchIndex < markerIndex)
    #expect(markerIndex < checkInIndex)
  }

  @Test func directionsToTheNextCheckInSurviveThePastStopTheyLeaveFrom() {
    let day = dogfoodDay()

    let today = projection(day.plan, now: date(day: 2, hour: 13, minute: 45), travelTimes: day.travelTimes)

    // The leg belongs to the 15:00 arrival, not to the lunch it departs.
    #expect(remainingItems(today).contains { item in
      guard case let .connector(connector) = item else { return false }
      return connector.kind == .toLodging && connector.to.id == "stay-\(day.stayID)"
    })
  }

  @Test func anAnchoredAnytimeStopFallsBehindYouButAFloatingOneDoesNot() {
    let anchored = dogfoodDay()
    let floatingID = UUID()
    let floating = plan(
      entries: [stop(floatingID, schedule: .day(2))],
      ideas: [idea(floatingID, name: "Wander")])
    let afternoon = date(day: 2, hour: 13, minute: 45)

    // Anchored to a 09:00 stop, the Anytime lunch sits at 09:00 in the weave — so
    // at 13:45 it is behind you, and the 15:00 check-in is what's next.
    let anchoredToday = projection(anchored.plan, now: afternoon, travelTimes: anchored.travelTimes)
    #expect(stopID(in: anchoredToday.next?.item) != anchored.lunchID)
    #expect(remainingItems(anchoredToday).contains { stopID(in: $0) == anchored.lunchID })
    // Un-anchored it floats at the end of the day — still ahead of you, never
    // dropped for "having no clock" the way `isUpcoming` used to drop it.
    let floatingToday = projection(floating, now: afternoon)
    #expect(stopID(in: floatingToday.next?.item) == floatingID)
  }

  @Test func aTimedCalendarConstraintCanBeNextButAllDayContextCannot() throws {
    let id = UUID()
    let civilDay = try #require(CalendarCivilDate(year: 2026, month: 8, day: 16))
    let nextCivilDay = try #require(CalendarCivilDate(year: 2026, month: 8, day: 17))
    let bookingStart = try #require(CalendarCivilDateTime(date: civilDay, hour: 16, minute: 0))
    let bookingEnd = try #require(CalendarCivilDateTime(date: civilDay, hour: 17, minute: 0))
    let bookingCommitment = try #require(CalendarCommitment(
      temporal: .floating(start: bookingStart, end: bookingEnd), availability: .busy))
    let strikeCommitment = try #require(CalendarCommitment(
      temporal: .allDay(start: civilDay, endExclusive: nextCivilDay), availability: .free))
    let timed = try #require(CalendarTripConstraint(
      id: UUID(),
      tripID: tripID,
      sourceIdentityHash: "timed",
      title: "Cable car booking",
      dayNumber: 2,
      startTime: "16:00",
      endTime: "17:00",
      commitment: bookingCommitment))
    let allDay = try #require(CalendarTripConstraint(
      id: UUID(),
      tripID: tripID,
      sourceIdentityHash: "all-day",
      title: "Transit strike",
      dayNumber: 2,
      startTime: nil,
      endTime: nil,
      commitment: strikeCommitment))
    var tripPlan = plan(
      entries: [stop(id, schedule: .timed(2, start: "09:00", end: nil))],
      ideas: [idea(id, name: "Morning walk")])
    tripPlan.calendarConstraints = [allDay, timed]

    let today = projection(tripPlan, now: date(day: 2, hour: 13, minute: 45))

    guard case let .calendarConstraint(constraint) = today.next?.item else {
      Issue.record("a 16:00 obligation is the next thing on the day")
      return
    }
    #expect(constraint.id == timed.id)
    // Day-long context is never something you leave for, but it stays on the day.
    #expect(remainingItems(today).contains { item in
      guard case let .calendarConstraint(constraint) = item else { return false }
      return constraint.id == allDay.id
    })
  }

  private func stopID(in item: ItineraryItem?) -> UUID? {
    guard case let .stop(stop) = item else { return nil }
    return stop.idea?.id
  }

  private func anchorCoordinate(for tripPlan: TripPlan, stop index: Int) -> WeatherAnchor.Coordinate? {
    WeatherAnchor.resolve(
      for: tripPlan.itinerary[0].stops[index],
      in: tripPlan,
      dayNumber: 1,
      tripStartDate: startDate)?.coordinate
  }
}
