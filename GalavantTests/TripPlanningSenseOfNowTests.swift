import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import Galavant

/// The planning surface's sense of *now* (the model half). `DayLensSeeding` and
/// the live-day derivation are tested purely in `GalavantSchema`; what this
/// covers is the wiring — that opening a trip that is underway actually moves the
/// canvas's day lens, and that a trip that isn't leaves it on "All".
@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TripPlanningSenseOfNowTests {
  @Dependency(\.defaultDatabase) private var database

  private static let tripStart = Calendar.current.date(
    from: DateComponents(year: 2026, month: 8, day: 15))!

  /// Noon on a 1-based trip day, relative to `tripStart`.
  private static func noon(onDay day: Int) -> Date {
    let dayDate = Calendar.current.date(byAdding: .day, value: day - 1, to: tripStart)!
    return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dayDate)!
  }

  private func makeTrip(startDate: Date?, lengthInDays: Int = 5) async throws -> Trip.ID {
    let tripID = UUID()
    try await database.write { db in
      try Trip.insert {
        Trip.Draft(
          Trip(
            id: tripID,
            name: "Dolomites",
            certaintyStage: startDate == nil ? .someday : .dated,
            startDate: startDate,
            lengthInDays: lengthInDays))
      }
      .execute(db)
    }
    return tripID
  }

  @MainActor
  private func loadedModel(tripID: Trip.ID) async throws -> TripPlanningModel {
    let model = TripPlanningModel(tripID: tripID)
    try await model.$trips.load()
    return model
  }

  @Test(.dependencies { $0.date = .constant(noon(onDay: 3)) })
  @MainActor
  func anUnderwayTripOpensOnItsLiveDay() async throws {
    let tripID = try await makeTrip(startDate: Self.tripStart)
    let model = try await loadedModel(tripID: tripID)
    #expect(model.canvasSelectedDay == nil)

    model.seedDayLensIfNeeded()

    #expect(model.liveDay == 3)
    #expect(model.canvasSelectedDay == 3)
  }

  @Test(.dependencies { $0.date = .constant(noon(onDay: 9)) })
  @MainActor
  func aFinishedTripKeepsTheWholeTripLens() async throws {
    let tripID = try await makeTrip(startDate: Self.tripStart)
    let model = try await loadedModel(tripID: tripID)

    model.seedDayLensIfNeeded()

    #expect(model.liveDay == nil)
    #expect(model.canvasSelectedDay == nil)
  }

  @Test(.dependencies { $0.date = .constant(noon(onDay: 2)) })
  @MainActor
  func anUndatedTripKeepsTheWholeTripLens() async throws {
    let tripID = try await makeTrip(startDate: nil)
    let model = try await loadedModel(tripID: tripID)

    model.seedDayLensIfNeeded()

    #expect(model.liveDay == nil)
    #expect(model.canvasSelectedDay == nil)
  }

  @Test(.dependencies { $0.date = .constant(noon(onDay: 2)) })
  @MainActor
  func seedingNeverOverridesTheDayTheUserChose() async throws {
    let tripID = try await makeTrip(startDate: Self.tripStart)
    let model = try await loadedModel(tripID: tripID)
    model.seedDayLensIfNeeded()
    #expect(model.canvasSelectedDay == 2)

    model.selectCanvasDay(4)
    model.seedDayLensIfNeeded()

    #expect(model.canvasSelectedDay == 4)
  }

  @Test(.dependencies { $0.date = .constant(noon(onDay: 2)) })
  @MainActor
  func theItineraryFollowsTheSelectedStayRatherThanToday() async throws {
    let tripID = try await makeTrip(startDate: Self.tripStart)
    let stayID = UUID()
    try await database.write { db in
      try TripStay.insert {
        TripStay.Draft(
          TripStay(
            id: stayID, tripID: tripID, ideaID: nil, inlineTitle: "Forestis",
            checkInDay: 4, checkOutDay: 5))
      }
      .execute(db)
    }
    let model = try await loadedModel(tripID: tripID)
    try await model.$allTripStays.load()
    #expect(model.itineraryFocusDay == 2)

    model.toggleCanvasStay(stayID)

    // A stay is a span: the list keeps the whole trip and moves to its first day.
    #expect(model.canvasSelectedDay == nil)
    #expect(model.itineraryFocusDay == 4)
    #expect(model.sheetTab == .itinerary)

    model.toggleCanvasStay(stayID)

    #expect(model.itineraryFocusDay == 2)
  }
}
