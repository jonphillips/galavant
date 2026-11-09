import Foundation
import GalavantSchema
import Testing

@Suite struct TripDayDesignTests {
  @Test("Rows project dated and undated day design, ignore orphans, and omit the last night")
  func rowsProjectDays() {
    let tripID = UUID()
    let otherTripID = UUID()
    let regionID = UUID()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 12))!
    let trip = Trip(id: tripID, name: "England", certaintyStage: .dated, startDate: start, lengthInDays: 3)
    let region = TripDayRegion(id: UUID(), tripID: tripID, dayNumber: 1, regionID: regionID)
    let orphanRegion = TripDayRegion(id: UUID(), tripID: tripID, dayNumber: 4, regionID: UUID())
    let wrongTripRegion = TripDayRegion(id: UUID(), tripID: otherTripID, dayNumber: 2, regionID: UUID())
    let zone = TripDayTimeZone(tripID: tripID, dayNumber: 1, timeZoneIdentifier: "Europe/London")
    let orphanZone = TripDayTimeZone(tripID: tripID, dayNumber: 4, timeZoneIdentifier: "Europe/Paris")
    let note = TripDayNote(tripID: tripID, dayNumber: 1, note: "Manchester concert")
    let orphanNote = TripDayNote(tripID: tripID, dayNumber: 4, note: "Past end")
    let stay = ResolvedStay(
      stay: TripStay.freeform(id: UUID(), tripID: tripID, title: "The Erst", checkInDay: 1, checkOutDay: 3),
      content: .stay(title: "The Erst", note: nil))

    let rows = TripDayDesign.rows(
      trip: trip, dayRegions: [region, orphanRegion, wrongTripRegion],
      dayTimeZones: [zone, orphanZone], dayNotes: [note, orphanNote], stays: [stay],
      stops: [], ideas: [], now: start)

    #expect(rows.count == 3)
    #expect(rows[0].date == trip.date(forDay: 1))
    #expect(rows[0].regionID == regionID)
    #expect(rows[0].timeZoneIdentifier == "Europe/London")
    #expect(rows[0].summary == "Manchester concert")
    #expect(rows[0].stayTitle == "The Erst")
    #expect(rows[1].regionID == nil)
    #expect(rows[1].timeZoneIdentifier == nil)
    #expect(rows[1].summary == nil)
    #expect(rows[1].stayTitle == "The Erst")
    #expect(rows[2].stayTitle == nil)

    let undated = Trip(id: UUID(), name: "Someday", lengthInDays: 1)
    let undatedRows = TripDayDesign.rows(
      trip: undated, dayRegions: [], dayTimeZones: [], dayNotes: [], stays: [],
      stops: [], ideas: [], now: start)
    #expect(undatedRows == [TripDayDesign(
      day: 1, date: nil, regionID: nil, timeZoneIdentifier: nil, summary: nil, stayTitle: nil)])
  }
}
