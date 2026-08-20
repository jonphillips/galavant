import Foundation
import GalavantSchema
import Testing

/// The outbound leg from a mid-day hotel check-in to the next activity — the
/// mirror of the existing return leg, so a changeover day reads symmetrically
/// (arriving hotel → stop → arriving hotel) instead of only showing the trip
/// home. See `TripPlan.arrivalConnector` / `arrivalToStopRoute`.
@Suite struct CheckInConnectorTests {
  private func idea(_ id: Idea.ID, lat: Double?, lon: Double?) -> Idea {
    Idea(id: id, name: "", latitude: lat, longitude: lon)
  }

  private func stop(idea: Idea.ID, at time: String, day: Int = 2) -> TripIdea {
    var e = TripIdea(
      id: UUID(), tripID: UUID(), ideaID: idea, status: .scheduled,
      shortlistRank: 0, dayRank: 0)
    e.apply(.timed(day, start: time, end: nil))
    return e
  }

  private func stay(
    idea: Idea.ID, checkIn: Int, checkOut: Int,
    checkInTime: String? = nil, checkOutTime: String? = nil
  ) -> TripStay {
    TripStay(
      id: UUID(), tripID: UUID(), ideaID: idea, inlineTitle: nil,
      checkInDay: checkIn, checkOutDay: checkOut,
      checkInTime: checkInTime, checkOutTime: checkOutTime,
      plannedCheckInTime: nil, plannedCheckOutTime: nil)
  }

  private func plan(
    entries: [TripIdea], stays: [TripStay], ideas: [Idea], lengthInDays: Int = 3
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

  /// A day with a morning activity, a mid-day check-in, and an evening activity:
  /// the outbound leg from the new hotel to the evening stop must appear —
  /// immediately after the check-in row and before the stop — alongside the
  /// existing return leg, so the day is symmetric.
  @Test func midDayCheckInEmitsOutboundConnectorToNextStop() {
    let (hotelA, hotelB, morning, evening) = (UUID(), UUID(), UUID(), UUID())
    let departing = stay(idea: hotelA, checkIn: 1, checkOut: 2, checkOutTime: "08:00")
    let arriving = stay(idea: hotelB, checkIn: 2, checkOut: 3, checkInTime: "15:00")
    let morningStop = stop(idea: morning, at: "10:00")   // before check-in
    let eveningStop = stop(idea: evening, at: "18:30")    // after check-in
    let p = plan(
      entries: [morningStop, eveningStop],
      stays: [departing, arriving],
      ideas: [
        idea(hotelA, lat: 10, lon: 10), idea(hotelB, lat: 20, lon: 20),
        idea(morning, lat: 1, lon: 1), idea(evening, lat: 2, lon: 2),
      ])

    // A leg is registered (so an ETA is fetched), and it is part of the plan's
    // full leg set.
    #expect(p.arrivalLegs(forDay: 2).count == 1)
    #expect(p.allLegs.contains(p.arrivalLegs(forDay: 2)[0]))

    let items = p.itineraryItems(
      forDay: 2, travelTimes: [:], effectiveModes: [:],
      stays: p.stays(coveringDay: 2))

    // Exactly one outbound leg from the arriving hotel, into the evening stop.
    let outbound = connectors(items).filter {
      $0.kind == .fromLodging && $0.from.id == "stay-\(arriving.id)"
    }
    #expect(outbound.count == 1)
    #expect(outbound.first?.to.id == "stop-\(eveningStop.id)")

    // Position: the check-in row, then the outbound connector, then the stop.
    guard let checkInIndex = items.firstIndex(where: {
      if case .checkIn(let s) = $0 { return s.id == arriving.id }
      return false
    }) else { Issue.record("no check-in row"); return }
    #expect({ if case .connector(let c) = items[checkInIndex + 1] { return c.kind == .fromLodging }
              else { return false } }())
    #expect(items[checkInIndex + 2] == .stop(p.itinerary[1].stops.first { $0.id == eveningStop.id }!))

    // The return leg still exists too — the day is symmetric, not just outbound.
    #expect(connectors(items).contains { $0.kind == .toLodging && $0.to.id == "stay-\(arriving.id)" })
  }

  /// An ordinary day inside a single stay (no check-in that day) gets no arrival
  /// connector — only the usual base/return legs.
  @Test func ordinaryStayDayHasNoArrivalConnector() {
    let (hotel, sight) = (UUID(), UUID())
    let s = stay(idea: hotel, checkIn: 1, checkOut: 3)
    let daySight = stop(idea: sight, at: "11:00")
    let p = plan(
      entries: [daySight], stays: [s],
      ideas: [idea(hotel, lat: 10, lon: 10), idea(sight, lat: 1, lon: 1)])

    #expect(p.arrivalLegs(forDay: 2).isEmpty)

    let items = p.itineraryItems(
      forDay: 2, travelTimes: [:], effectiveModes: [:],
      stays: p.stays(coveringDay: 2))
    // Only one lodging→stop connector (the base), never a duplicate.
    #expect(connectors(items).filter { $0.kind == .fromLodging }.count == 1)
  }

  /// When the day's *first* located stop is already after the check-in, the base
  /// connector already draws arriving-hotel → that stop, so no separate arrival
  /// connector is emitted (no double).
  @Test func firstStopAfterCheckInIsNotDoubled() {
    let (hotelA, hotelB, afternoon) = (UUID(), UUID(), UUID())
    let departing = stay(idea: hotelA, checkIn: 1, checkOut: 2, checkOutTime: "08:00")
    let arriving = stay(idea: hotelB, checkIn: 2, checkOut: 3, checkInTime: "15:00")
    let afternoonStop = stop(idea: afternoon, at: "18:00")  // the only stop, after check-in
    let p = plan(
      entries: [afternoonStop],
      stays: [departing, arriving],
      ideas: [
        idea(hotelA, lat: 10, lon: 10), idea(hotelB, lat: 20, lon: 20),
        idea(afternoon, lat: 3, lon: 3),
      ])

    // Base already covers arriving-hotel → afternoon stop, so no arrival leg.
    #expect(p.arrivalLegs(forDay: 2).isEmpty)

    let items = p.itineraryItems(
      forDay: 2, travelTimes: [:], effectiveModes: [:],
      stays: p.stays(coveringDay: 2))
    let outbound = connectors(items).filter { $0.kind == .fromLodging }
    #expect(outbound.count == 1)
    #expect(outbound.first?.from.id == "stay-\(arriving.id)")
    #expect(outbound.first?.to.id == "stop-\(afternoonStop.id)")
  }
}
