import Foundation
import GalavantAI
import GalavantPlaces
@testable import GalavantSchema
import Testing

struct GalavantChatExportTests {
  @Test func exportUsesTheBriefPlanAndRuledOutProjectionsAndKeepsUndatedTrips() throws {
    let tripID = UUID()
    let trip = Trip(id: tripID, name: "Copenhagen", notes: "Slow days", startDate: nil, lengthInDays: 4)
    let entries = [
      TripIdea(id: UUID(), tripID: tripID, ideaID: nil, inlineTitle: "Louisiana", status: .scheduled, dayNumber: 1),
      TripIdea(id: UUID(), tripID: tripID, ideaID: nil, inlineTitle: "Skip the tower", inlineNote: "Too crowded", status: .declined)
    ]
    let stays = [TripStay.freeform(id: UUID(), tripID: tripID, title: "Hotel d'Angleterre", checkInDay: 1, checkOutDay: 3)]
    let plan = TripPlan(entries: entries, ideasByID: [:], lengthInDays: trip.lengthInDays, tripStays: stays)
    let session = HandoffSession(sourceType: "trip", sourceID: tripID,
      taskType: RecommendationHandoffTask.candidatePlaces, exportedPrompt: "")
    let brief = RecommendationHandoffContract.brief(session: session, tripName: trip.name,
      tripNotes: trip.notes, plan: plan)
    let export = try GalavantChatExportBuilder.build(trips: [trip], entries: entries, ideas: [], stays: stays,
      dayRegions: [], regions: [], constraints: [], alternativeGroups: [], profiles: [], planners: [],
      generatedAt: Date(timeIntervalSince1970: 100), device: "iPhone")
    let exported = try #require(export.trips.first)
    #expect(exported.planLines == RecommendationHandoffContract.stopSummary(plan: plan))
    #expect(exported.ruledOutLines == RecommendationHandoffContract.ruledOutSummary(plan: plan))
    #expect(brief.contains(exported.planLines.joined(separator: "\n")))
    #expect(brief.contains(exported.ruledOutLines.joined(separator: "\n")))
    #expect(exported.startDate == nil)
    #expect(exported.lengthInDays == 4)
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(export)) as? [String: Any])
    let tripObject = try #require((encoded["trips"] as? [[String: Any]])?.first)
    #expect(Set(tripObject.keys) == ["id", "name", "startDate", "targetYear", "targetQuarter", "lengthInDays",
      "notes", "planLines", "ruledOutLines", "tasteLines", "consideringTitles", "shortlistedTitles"])
  }

  @Test func encodedKeysAreExactAndVersionIsChecked() throws {
    let export = GalavantChatExport(generatedAt: Date(timeIntervalSince1970: 100), device: "iPad", trips: [])
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(export)) as? [String: Any])
    #expect(Set(object.keys) == ["version", "generatedAt", "device", "trips"])
    #expect(try GalavantChatExport.decode(JSONEncoder().encode(export)) == export)
    let newer = Data(#"{"version":2,"generatedAt":0,"device":"iPad","trips":[]}"#.utf8)
    #expect(throws: GalavantChatExport.DecodeError.unsupportedVersion(2)) {
      try GalavantChatExport.decode(newer)
    }
  }

  @Test func startDateExportsTheDeviceCalendarDayInsteadOfTheStoredInstant() throws {
    let formatter = ISO8601DateFormatter()
    let storedDate = try #require(formatter.date(from: "2027-03-11T02:30:00Z"))
    let trip = Trip(id: UUID(), name: "Los Angeles", notes: "", startDate: storedDate, lengthInDays: 3)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let export = try GalavantChatExportBuilder.build(trips: [trip], entries: [], ideas: [], stays: [],
      dayRegions: [], regions: [], constraints: [], alternativeGroups: [], profiles: [], planners: [],
      generatedAt: Date(timeIntervalSince1970: 0), device: "iPhone", calendar: calendar)
    #expect(export.trips.first?.startDate == "2027-03-10")
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(export)) as? [String: Any])
    let encodedTrip = try #require((encoded["trips"] as? [[String: Any]])?.first)
    #expect(encodedTrip["startDate"] as? String == "2027-03-10")
  }

  @Test func tripOrderingKeepsTripsActiveThroughTheirLastDay() throws {
    let today = try #require(CalendarCivilDate(year: 2027, month: 3, day: 10))
    let lastDay = GalavantChatExport.Trip(id: UUID(), name: "Last day", startDate: "2027-03-06", lengthInDays: 5,
      notes: "", planLines: [], ruledOutLines: [], tasteLines: [], consideringTitles: [], shortlistedTitles: [])
    let firstDay = GalavantChatExport.Trip(id: UUID(), name: "First day", startDate: "2027-03-10", lengthInDays: 5,
      notes: "", planLines: [], ruledOutLines: [], tasteLines: [], consideringTitles: [], shortlistedTitles: [])
    let undated = GalavantChatExport.Trip(id: UUID(), name: "Someday", startDate: nil, lengthInDays: 5,
      notes: "", planLines: [], ruledOutLines: [], tasteLines: [], consideringTitles: [], shortlistedTitles: [])
    let dayAfter = GalavantChatExport.Trip(id: UUID(), name: "Past", startDate: "2027-03-05", lengthInDays: 5,
      notes: "", planLines: [], ruledOutLines: [], tasteLines: [], consideringTitles: [], shortlistedTitles: [])

    let ordered = GalavantChatExport.ordered([undated, dayAfter, firstDay, lastDay], today: today)
    #expect(ordered.map(\.id) == [lastDay.id, firstDay.id, undated.id, dayAfter.id])
  }
}
