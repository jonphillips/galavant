import Foundation
import GalavantSchema
import Testing

@Suite struct JourneyProjectionTests {
  private let startDate = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func projectsDaysStaysSummaryAndTransferOrientation() {
    let firstHotelID = UUID()
    let secondHotelID = UUID()
    let trailID = UUID()
    let cafeID = UUID()
    let regionID = UUID()
    let tripID = UUID()
    let region = MapRegion(
      id: regionID,
      name: "Old Town",
      centerLatitude: 10,
      centerLongitude: 20,
      latitudeDelta: 1,
      longitudeDelta: 1)
    let firstStay = TripStay(
      id: UUID(), tripID: tripID, ideaID: firstHotelID, checkInDay: 1, checkOutDay: 4)
    let secondStay = TripStay(
      id: UUID(), tripID: tripID, ideaID: secondHotelID, checkInDay: 4, checkOutDay: 6)
    let trail = scheduledStop(trailID, day: 1)
    let cafe = scheduledStop(cafeID, day: 2)
    let plan = TripPlan(
      entries: [trail, cafe],
      ideasByID: [
        firstHotelID: Idea(
          id: firstHotelID, name: "First Hotel", regionName: "Old Town", latitude: 1, longitude: 2),
        secondHotelID: Idea(
          id: secondHotelID, name: "Second Hotel", regionName: "New Town", latitude: 3, longitude: 4),
        trailID: Idea(
          id: trailID, name: "Cliff Trail", kind: .outdoorTrail, latitude: 5, longitude: 6),
        cafeID: Idea(id: cafeID, name: "Cafe", regionName: "Old Town", latitude: 7, longitude: 8)
      ],
      lengthInDays: 5,
      tripStays: [firstStay, secondStay],
      dayRegions: [TripDayRegion(id: UUID(), tripID: tripID, dayNumber: 1, regionID: regionID)],
      regionsByID: [regionID: region])

    let projection = JourneyProjection.resolve(from: plan, tripStartDate: startDate)

    #expect(projection.days.count == 5)
    #expect(projection.days[0].locality == "Old Town")
    #expect(projection.days[0].stopTitles == ["Cliff Trail"])
    #expect(projection.days[0].definingStop?.title == "Cliff Trail")
    #expect(projection.days[0].weatherAnchors.first?.coordinate == .init(latitude: 5, longitude: 6))
    #expect(projection.stayBands.map(\.nights) == [1..<4, 4..<6])
    #expect(projection.days[3].isTransfer)
    #expect(projection.days[3].transferFrom?.title == "First Hotel")
    #expect(projection.days[3].transferTo?.title == "Second Hotel")
    #expect(projection.summary.dayCount == 5)
    #expect(projection.summary.nightCount == 4)
    #expect(projection.summary.regionNames == ["Old Town", "New Town"])
    #expect(projection.summary.stayCount == 2)
    #expect(projection.summary.transferDayCount == 1)
  }

  @Test func dayWeatherFallsBackToRegionAndOmitsWhenNothingLocates() {
    let regionID = UUID()
    let region = MapRegion(
      id: regionID,
      name: "Region",
      centerLatitude: 30,
      centerLongitude: 40,
      latitudeDelta: 1,
      longitudeDelta: 1)
    let regionPlan = TripPlan(
      entries: [],
      ideasByID: [:],
      lengthInDays: 1,
      dayRegions: [TripDayRegion(id: UUID(), tripID: UUID(), dayNumber: 1, regionID: regionID)],
      regionsByID: [regionID: region])
    let emptyPlan = TripPlan(entries: [], ideasByID: [:], lengthInDays: 1)

    let regionProjection = JourneyProjection.resolve(from: regionPlan, tripStartDate: startDate)
    let emptyProjection = JourneyProjection.resolve(from: emptyPlan, tripStartDate: startDate)

    #expect(regionProjection.days[0].weatherAnchors.first?.coordinate == .init(latitude: 30, longitude: 40))
    #expect(emptyProjection.days[0].weatherAnchors.isEmpty)
  }

  @Test func transferDayCountCountsEachContiguousHandoff() {
    let tripID = UUID()
    let firstStay = TripStay.freeform(
      id: UUID(), tripID: tripID, title: "First Hotel", checkInDay: 1, checkOutDay: 2,
      plannedCheckOutTime: "09:00")
    let secondStay = TripStay.freeform(
      id: UUID(), tripID: tripID, title: "Second Hotel", checkInDay: 2, checkOutDay: 4,
      plannedCheckInTime: "17:00", plannedCheckOutTime: "09:00")
    let thirdStay = TripStay.freeform(
      id: UUID(), tripID: tripID, title: "Third Hotel", checkInDay: 4, checkOutDay: 5,
      plannedCheckInTime: "17:00")
    var stop = TripIdea.freeform(
      id: UUID(), tripID: tripID, title: "Lunch", latitude: 1, longitude: 2)
    stop.apply(.timed(2, start: "12:00", end: "13:00"))
    let plan = TripPlan(
      entries: [stop],
      ideasByID: [:],
      lengthInDays: 5,
      tripStays: [firstStay, secondStay, thirdStay])

    let projection = JourneyProjection.resolve(from: plan, tripStartDate: startDate)

    #expect(!projection.days[1].isTransfer)
    #expect(projection.summary.transferDayCount == 2)
  }

  @Test func transferDayCountDoesNotBridgeAStayGap() {
    let tripID = UUID()
    let plan = TripPlan(
      entries: [],
      ideasByID: [:],
      lengthInDays: 4,
      tripStays: [
        .freeform(id: UUID(), tripID: tripID, title: "First Hotel", checkInDay: 1, checkOutDay: 2),
        .freeform(id: UUID(), tripID: tripID, title: "Second Hotel", checkInDay: 3, checkOutDay: 4)
      ])

    let projection = JourneyProjection.resolve(from: plan, tripStartDate: startDate)

    #expect(projection.summary.transferDayCount == 0)
  }

  @Test func singleStayHasNoTransferDays() {
    let tripID = UUID()
    let plan = TripPlan(
      entries: [],
      ideasByID: [:],
      lengthInDays: 4,
      tripStays: [
        .freeform(id: UUID(), tripID: tripID, title: "One Hotel", checkInDay: 1, checkOutDay: 4)
      ])

    let projection = JourneyProjection.resolve(from: plan, tripStartDate: startDate)

    #expect(projection.summary.transferDayCount == 0)
  }

  private func scheduledStop(_ ideaID: Idea.ID, day: Int) -> TripIdea {
    var entry = TripIdea(id: UUID(), tripID: UUID(), ideaID: ideaID, status: .scheduled)
    entry.apply(.day(day))
    return entry
  }
}
