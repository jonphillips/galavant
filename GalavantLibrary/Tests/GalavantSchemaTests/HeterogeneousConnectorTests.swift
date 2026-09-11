import Foundation
import GalavantSchema
import Testing

/// Directions between *any* adjacent located waypoints (dogfood Slice C). The
/// four hand-written lodging cases became one rule over the day's ordered
/// located-waypoint chain, so heterogeneous days — overlapping stays, a stay
/// that leaves with none arriving, a stop next to a check-in, an unlocated stay —
/// draw connectors instead of silently dropping them.
///
/// Each numbered gap the rewrite closed has a named test here; the last two pin
/// the invariant that a leg to a place with no coordinate is worse than no leg,
/// so unlocated endpoints still produce nothing.
@Suite struct HeterogeneousConnectorTests {
  private func idea(_ id: Idea.ID, _ name: String = "", lat: Double?, lon: Double?) -> Idea {
    Idea(id: id, name: name, latitude: lat, longitude: lon)
  }

  private func stop(_ ideaID: Idea.ID, at time: String, day: Int = 2) -> TripIdea {
    var entry = TripIdea(
      id: UUID(), tripID: UUID(), ideaID: ideaID, status: .scheduled,
      shortlistRank: 0, dayRank: 0)
    entry.apply(.timed(day, start: time, end: nil))
    return entry
  }

  private func stay(
    _ ideaID: Idea.ID? = nil, title: String? = nil,
    checkIn: Int, checkOut: Int, checkInTime: String? = nil, checkOutTime: String? = nil
  ) -> TripStay {
    TripStay(
      id: UUID(), tripID: UUID(), ideaID: ideaID, inlineTitle: title,
      checkInDay: checkIn, checkOutDay: checkOut,
      checkInTime: checkInTime, checkOutTime: checkOutTime,
      plannedCheckInTime: nil, plannedCheckOutTime: nil)
  }

  private func plan(
    entries: [TripIdea], stays: [TripStay], ideas: [Idea], lengthInDays: Int = 6
  ) -> TripPlan {
    TripPlan(
      entries: entries,
      ideasByID: Dictionary(ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      lengthInDays: lengthInDays,
      tripStays: stays)
  }

  private func connectors(_ items: [ItineraryItem]) -> [TravelConnector] {
    items.compactMap { if case .connector(let c) = $0 { c } else { nil } }
  }

  // MARK: - The dogfood repro

  /// The complaint that started the slice: a located stop followed by a located
  /// check-in (St Maddalena → Forestis) with no directions between them. The leg
  /// must exist and render *adjacent to the check-in row*, not floated to the end.
  @Test func locatedStopIntoLocatedCheckInDrawsALeg() {
    let (hotel, sight) = (UUID(), UUID())
    let arriving = stay(hotel, checkIn: 2, checkOut: 4, checkInTime: "15:00")
    let lunch = stop(sight, at: "12:00")
    let p = plan(
      entries: [lunch], stays: [arriving],
      ideas: [idea(hotel, "Forestis", lat: 46.6, lon: 11.7),
              idea(sight, "St Maddalena", lat: 46.6, lon: 11.7)])

    let leg = LegKey(fromLat: 46.6, fromLon: 11.7, toLat: 46.6, toLon: 11.7)
    #expect(p.allLegs.contains(leg))
    #expect(p.returnLegs(forDay: 2) == [leg])  // stop → the hotel you check into

    let items = p.itineraryItems(
      forDay: 2, travelTimes: [:], effectiveModes: [:], stays: p.stays(coveringDay: 2))
    // stop(12:00), directions, check-in(15:00) — the leg sits *between* them.
    guard let checkInIndex = items.firstIndex(where: {
      if case .checkIn = $0 { return true }; return false
    }) else { Issue.record("no check-in row"); return }
    #expect(checkInIndex >= 1)
    if case .connector(let c) = items[checkInIndex - 1] {
      #expect(c.kind == .toLodging)
      #expect(c.to.id == "stay-\(arriving.id)")
    } else {
      Issue.record("the leg into the check-in should render immediately before it")
    }
  }

  // MARK: - Gap 1 — overlapping stays covering one day

  /// Two stays covering the same night is an allowed, advisory state (ADR-0011
  /// §6). The old four cases required exactly one departure + one arrival and
  /// returned nil for anything else, so every lodging leg on an overlap day
  /// vanished. The chain degrades gracefully: the day's legs still exist.
  @Test func overlappingStaysStillDrawLodgingLegs() {
    let (hotelA, hotelB, sight) = (UUID(), UUID(), UUID())
    // A and B both cover the night before day 2; A checks out on day 2, B stays on.
    let leaving = stay(hotelA, checkIn: 1, checkOut: 2)
    let staying = stay(hotelB, checkIn: 1, checkOut: 5)
    let museum = stop(sight, at: "12:00")
    let p = plan(
      entries: [museum], stays: [leaving, staying],
      ideas: [idea(hotelA, "A", lat: 1, lon: 1), idea(hotelB, "B", lat: 2, lon: 2),
              idea(sight, "Museum", lat: 3, lon: 3)])

    // Previously every lodging leg was nil here; now the day is connected.
    #expect(!p.allLegs.isEmpty)
    #expect(!p.baseLegs(forDay: 2).isEmpty)
    // A leg reaches the museum, and the night is spent back at the staying hotel.
    #expect(p.allLegs.contains(LegKey(fromLat: 1, fromLon: 1, toLat: 3, toLon: 3)))
    #expect(p.returnLegs(forDay: 2) == [LegKey(fromLat: 3, fromLon: 3, toLat: 2, toLon: 2)])
  }

  // MARK: - Gap 2 — a calendar constraint is transparent

  /// A `CalendarTripConstraint` carries no coordinate, so it can never be a route
  /// endpoint. The rule treats it as transparent: it neither anchors a leg nor
  /// breaks the stop chain around it, so a stop → obligation → stop day keeps its
  /// stop-to-stop directions and no leg names the constraint.
  @Test func calendarConstraintIsTransparentToTheRoute() {
    let (first, second) = (UUID(), UUID())
    let morning = stop(first, at: "10:00")
    let afternoon = stop(second, at: "16:00")
    let noon = Date(timeIntervalSince1970: 1_000_000)
    let commitment = CalendarCommitment(
      temporal: .absolute(
        start: noon, end: noon.addingTimeInterval(3600),
        timeZone: TimeZone(identifier: "Europe/Rome")!),
      availability: .busy)!
    let constraint = CalendarTripConstraint(
      id: UUID(), tripID: UUID(), sourceIdentityHash: "hash",
      title: "Call the accountant", dayNumber: 2,
      startTime: "13:00", endTime: "14:00",
      commitment: commitment)!
    let p = TripPlan(
      entries: [morning, afternoon],
      ideasByID: [first: idea(first, "Museum", lat: 1, lon: 1),
                  second: idea(second, "Park", lat: 2, lon: 2)],
      lengthInDays: 6,
      calendarConstraints: [constraint])

    // The stop-to-stop leg survives the obligation between them…
    let leg = LegKey(fromLat: 1, fromLon: 1, toLat: 2, toLon: 2)
    #expect(p.allLegs == [leg])
    // …and no leg has an endpoint that is the constraint.
    #expect(p.legIdentities.values.allSatisfy {
      !$0.from.contains("\(constraint.id)") && !$0.to.contains("\(constraint.id)")
    })

    let items = p.itineraryItems(forDay: 2, travelTimes: [:], effectiveModes: [:])
    #expect(items.contains { if case .calendarConstraint = $0 { true } else { false } })
    #expect(connectors(items).count == 1)
  }

  // MARK: - Gap 3 — a stay leaves, none arrives, a stop follows

  /// On a changeover day where a stay checks out and a *different* stay is
  /// mid-stay (no arrival that day), the old base rule required one departure and
  /// one arrival and returned nil — so the leg out of the departing hotel to the
  /// day's first stop was missing. The chain draws it.
  @Test func checkOutToFirstStopDrawsWhenNoStayArrives() {
    let (hotelA, hotelB, sight) = (UUID(), UUID(), UUID())
    let leaving = stay(hotelA, checkIn: 1, checkOut: 2)     // checks out on day 2
    let staying = stay(hotelB, checkIn: 1, checkOut: 5)     // mid-stay on day 2
    let museum = stop(sight, at: "11:00")
    let p = plan(
      entries: [museum], stays: [leaving, staying],
      ideas: [idea(hotelA, "A", lat: 1, lon: 1), idea(hotelB, "B", lat: 2, lon: 2),
              idea(sight, "Museum", lat: 3, lon: 3)])

    // The checkout hotel → first stop leg now exists (from-lodging into the museum).
    #expect(p.baseLegs(forDay: 2) == [LegKey(fromLat: 1, fromLon: 1, toLat: 3, toLon: 3)])
    let items = p.itineraryItems(
      forDay: 2, travelTimes: [:], effectiveModes: [:], stays: p.stays(coveringDay: 2))
    #expect(connectors(items).contains {
      $0.kind == .fromLodging && $0.from.id == "stay-\(leaving.id)"
    })
  }

  // MARK: - Gap 4 — a stop before a mid-day check-in, more stops after

  /// A stop before a mid-day check-in and another after it: the leg *into* the
  /// check-in used to be appended after the last stop of the day. It must render
  /// adjacent to the check-in row, and the outbound leg from the new hotel still
  /// draws for the later stop.
  @Test func stopBeforeMidDayCheckInRendersTheLegAtTheCheckIn() {
    let (hotel, morningID, eveningID) = (UUID(), UUID(), UUID())
    let arriving = stay(hotel, checkIn: 2, checkOut: 4, checkInTime: "15:00")
    let morning = stop(morningID, at: "10:00")
    let evening = stop(eveningID, at: "18:30")
    let p = plan(
      entries: [morning, evening], stays: [arriving],
      ideas: [idea(hotel, "Hotel", lat: 2, lon: 2),
              idea(morningID, "Morning", lat: 1, lon: 1),
              idea(eveningID, "Evening", lat: 3, lon: 3)])

    let items = p.itineraryItems(
      forDay: 2, travelTimes: [:], effectiveModes: [:], stays: p.stays(coveringDay: 2))
    guard let checkInIndex = items.firstIndex(where: {
      if case .checkIn = $0 { return true }; return false
    }) else { Issue.record("no check-in row"); return }

    // The leg into the check-in sits immediately before it (morning stop → hotel).
    if case .connector(let into) = items[checkInIndex - 1] {
      #expect(into.kind == .toLodging)
      #expect(into.from.id == "stop-\(morning.id)")
    } else {
      Issue.record("the leg into the check-in should render immediately before it")
    }
    // The outbound leg to the evening stop follows the check-in row.
    if case .connector(let out) = items[checkInIndex + 1] {
      #expect(out.kind == .fromLodging)
      #expect(out.to.id == "stop-\(evening.id)")
    } else {
      Issue.record("the outbound leg should render right after the check-in")
    }
  }

  // MARK: - Gap 5 — an unlocated stay takes no leg down with it

  /// A stay with no coordinate (freeform lodging) covering the day must not erase
  /// the day's other legs. The stops still connect and no leg names the unlocated
  /// stay.
  @Test func unlocatedStayLeavesTheStopLegsIntact() {
    let (first, second) = (UUID(), UUID())
    let couch = stay(title: "Friend's spare room", checkIn: 1, checkOut: 5)  // no coordinate
    let morning = stop(first, at: "10:00")
    let afternoon = stop(second, at: "15:00")
    let p = plan(
      entries: [morning, afternoon], stays: [couch],
      ideas: [idea(first, "Museum", lat: 1, lon: 1), idea(second, "Park", lat: 2, lon: 2)])

    // The stop-to-stop leg survives; no leg touches the unlocated stay.
    #expect(p.allLegs == [LegKey(fromLat: 1, fromLon: 1, toLat: 2, toLon: 2)])
    #expect(p.baseLegs(forDay: 2).isEmpty)
    #expect(p.returnLegs(forDay: 2).isEmpty)
    #expect(p.legIdentities.values.allSatisfy {
      !$0.from.hasPrefix("stay-") && !$0.to.hasPrefix("stay-")
    })
  }

  // MARK: - A leg to nowhere is worse than no leg

  /// An unlocated stop between a located stop and a located check-in breaks the
  /// chain the same way it breaks a stop-to-stop chain — no phantom leg is forged
  /// past the place we cannot route to.
  @Test func unlocatedStopBetweenStopAndCheckInProducesNoLegAcrossIt() {
    let (hotel, located, unlocated) = (UUID(), UUID(), UUID())
    let arriving = stay(hotel, checkIn: 2, checkOut: 4, checkInTime: "20:00")
    let museum = stop(located, at: "10:00")
    let errand = stop(unlocated, at: "12:00")  // no coordinate
    let p = plan(
      entries: [museum, errand], stays: [arriving],
      ideas: [idea(hotel, "Hotel", lat: 5, lon: 5),
              idea(located, "Museum", lat: 1, lon: 1),
              idea(unlocated, "Errand", lat: nil, lon: nil)])

    // Museum → Errand is impossible (Errand has no coords), so the located museum
    // still returns to the hotel it checks into, but nothing routes through Errand.
    #expect(p.legs(forDay: 2).isEmpty)  // no stop→stop leg across the gap
    #expect(p.allLegs == [LegKey(fromLat: 1, fromLon: 1, toLat: 5, toLon: 5)])  // museum → hotel only
  }

  @Test func aDayOfOnlyUnlocatedThingsHasNoLegs() {
    let (stopID, hotel) = (UUID(), UUID())
    let arriving = stay(hotel, checkIn: 2, checkOut: 4)  // unlocated hotel
    let note = stop(stopID, at: "10:00")                 // unlocated stop
    let p = plan(
      entries: [note], stays: [arriving],
      ideas: [idea(stopID, "Note", lat: nil, lon: nil), idea(hotel, "Hotel", lat: nil, lon: nil)])
    #expect(p.allLegs.isEmpty)
  }
}
