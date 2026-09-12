import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

/// The trip sketch (docs/handoff/trip-sketch-design.md): the pure span projection
/// over per-day region assignments, plus the two write ops that persist a sketch.
@Suite struct TripSketchTests {
  private func row(_ tripID: Trip.ID = UUID(), day: Int, region: MapRegion.ID) -> TripDayRegion {
    TripDayRegion(id: UUID(), tripID: tripID, dayNumber: day, regionID: region)
  }

  // MARK: - Span projection (pure)

  @Test("An unassigned trip is one nil span covering every day")
  func emptyTripIsOneNilSpan() {
    let sketch = TripSketch(lengthInDays: 8, dayRegions: [])
    #expect(sketch.spans == [DaySpan(startDay: 1, endDay: 8, regionID: nil)])
    #expect(sketch.lengthInDays == 8)
  }

  @Test("Adjacent same-region days coalesce; a change starts a new span")
  func adjacentSameRegionCoalesces() {
    let loire = UUID()
    let paris = UUID()
    let tripID = UUID()
    let sketch = TripSketch(
      lengthInDays: 8,
      dayRegions: [
        row(tripID, day: 1, region: loire), row(tripID, day: 2, region: loire),
        row(tripID, day: 3, region: loire), row(tripID, day: 4, region: loire),
        row(tripID, day: 5, region: paris), row(tripID, day: 6, region: paris),
        row(tripID, day: 7, region: paris),
        // day 8 left unassigned (fly home)
      ])
    #expect(sketch.spans == [
      DaySpan(startDay: 1, endDay: 4, regionID: loire),
      DaySpan(startDay: 5, endDay: 7, regionID: paris),
      DaySpan(startDay: 8, endDay: 8, regionID: nil),
    ])
  }

  @Test("A gap between two assigned runs surfaces as its own nil span")
  func unassignedGapIsItsOwnSpan() {
    let loire = UUID()
    let sketch = TripSketch(
      lengthInDays: 5,
      dayRegions: [row(day: 1, region: loire), row(day: 5, region: loire)])
    #expect(sketch.spans == [
      DaySpan(startDay: 1, endDay: 1, regionID: loire),
      DaySpan(startDay: 2, endDay: 4, regionID: nil),
      DaySpan(startDay: 5, endDay: 5, regionID: loire),
    ])
  }

  @Test("The same region on two non-adjacent runs stays two spans")
  func sameRegionNonAdjacentStaysSplit() {
    let loire = UUID()
    let paris = UUID()
    let sketch = TripSketch(
      lengthInDays: 5,
      dayRegions: [
        row(day: 1, region: loire), row(day: 2, region: loire),
        row(day: 3, region: paris),
        row(day: 4, region: loire), row(day: 5, region: loire),
      ])
    #expect(sketch.spans == [
      DaySpan(startDay: 1, endDay: 2, regionID: loire),
      DaySpan(startDay: 3, endDay: 3, regionID: paris),
      DaySpan(startDay: 4, endDay: 5, regionID: loire),
    ])
  }

  @Test("Day rows past the trip length (orphans) are dropped on load")
  func orphanDayRowsDropped() {
    let loire = UUID()
    let sketch = TripSketch(
      lengthInDays: 3,
      dayRegions: [row(day: 1, region: loire), row(day: 9, region: loire)])
    #expect(sketch.spans == [
      DaySpan(startDay: 1, endDay: 1, regionID: loire),
      DaySpan(startDay: 2, endDay: 3, regionID: nil),
    ])
    #expect(sketch.assignments() == [1: loire])
  }

  // MARK: - Assignment (pure)

  @Test("Assigning a sub-range splits a span into two")
  func assignSubRangeSplits() {
    let loire = UUID()
    let paris = UUID()
    var sketch = TripSketch(lengthInDays: 7, dayRegions: [])
    sketch.assign(loire, toDays: 1...4)
    sketch.assign(paris, toDays: 5...7)
    #expect(sketch.spans == [
      DaySpan(startDay: 1, endDay: 4, regionID: loire),
      DaySpan(startDay: 5, endDay: 7, regionID: paris),
    ])
  }

  @Test("Clearing a middle range reopens an unassigned gap")
  func clearMiddleRangeReopensGap() {
    let loire = UUID()
    var sketch = TripSketch(lengthInDays: 5, dayRegions: [])
    sketch.assign(loire, toDays: 1...5)
    sketch.assign(nil, toDays: 3...3)
    #expect(sketch.spans == [
      DaySpan(startDay: 1, endDay: 2, regionID: loire),
      DaySpan(startDay: 3, endDay: 3, regionID: nil),
      DaySpan(startDay: 4, endDay: 5, regionID: loire),
    ])
  }

  @Test("Assignment is clamped to the trip's day range")
  func assignmentClampedToRange() {
    let loire = UUID()
    var sketch = TripSketch(lengthInDays: 3, dayRegions: [])
    sketch.assign(loire, toDays: 0...9)
    #expect(sketch.assignments() == [1: loire, 2: loire, 3: loire])
    // A fully out-of-range assignment is a no-op, not a crash.
    sketch.assign(UUID(), toDays: 10...12)
    #expect(sketch.assignments() == [1: loire, 2: loire, 3: loire])
  }

  // MARK: - Length changes (pure)

  @Test("Growing the trip appends unassigned days")
  func growAppendsUnassignedDays() {
    let loire = UUID()
    var sketch = TripSketch(lengthInDays: 3, dayRegions: [])
    sketch.assign(loire, toDays: 1...3)
    sketch.setLength(6)
    #expect(sketch.lengthInDays == 6)
    #expect(sketch.spans == [
      DaySpan(startDay: 1, endDay: 3, regionID: loire),
      DaySpan(startDay: 4, endDay: 6, regionID: nil),
    ])
  }

  @Test("Shortening the trip drops the tail days and their assignments")
  func shorteningDropsTailAssignments() {
    let loire = UUID()
    let paris = UUID()
    var sketch = TripSketch(lengthInDays: 6, dayRegions: [])
    sketch.assign(loire, toDays: 1...3)
    sketch.assign(paris, toDays: 4...6)
    sketch.setLength(3)
    #expect(sketch.lengthInDays == 3)
    #expect(sketch.assignments() == [1: loire, 2: loire, 3: loire])
    #expect(sketch.spans == [DaySpan(startDay: 1, endDay: 3, regionID: loire)])
  }

  @Test("Length is clamped to at least one day")
  func lengthClampedToOne() {
    var sketch = TripSketch(lengthInDays: 4, dayRegions: [])
    sketch.setLength(0)
    #expect(sketch.lengthInDays == 1)
    #expect(sketch.spans == [DaySpan(startDay: 1, endDay: 1, regionID: nil)])
  }

  @Test("assignments() omits unassigned days")
  func assignmentsOmitsUnassigned() {
    let loire = UUID()
    var sketch = TripSketch(lengthInDays: 5, dayRegions: [])
    sketch.assign(loire, toDays: 2...3)
    #expect(sketch.assignments() == [2: loire, 3: loire])
  }
}

/// The sketch's persistence: `TripDayRegion.replaceAssignments` and `Trip.setLength`.
@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TripSketchPersistenceTests {
  @Dependency(\.defaultDatabase) var database

  @Test("replaceAssignments writes the listed days and drops everything else")
  func replaceAssignmentsReconcilesWholeLayout() async throws {
    let loire = UUID()
    let paris = UUID()
    let rows = try await database.write { db -> [TripDayRegion] in
      let trip = try Trip.create(name: "France", lengthInDays: 7, in: db)
      // Seed a layout the old per-day way, plus an orphan past a since-shortened length.
      try TripDayRegion.setRegion(loire, forTrip: trip.id, day: 1, in: db)
      try TripDayRegion.setRegion(loire, forTrip: trip.id, day: 2, in: db)
      try TripDayRegion.setRegion(paris, forTrip: trip.id, day: 3, in: db)
      try TripDayRegion.setRegion(paris, forTrip: trip.id, day: 9, in: db)  // orphan
      // Re-shape: days 1–3 Loire, day 4 Paris; everything else cleared/dropped.
      try TripDayRegion.replaceAssignments(
        [1: loire, 2: loire, 3: loire, 4: paris], forTrip: trip.id, in: db)
      return try TripDayRegion.where { $0.tripID.eq(trip.id) }.fetchAll(db)
    }
    let byDay = Dictionary(uniqueKeysWithValues: rows.map { ($0.dayNumber, $0.regionID) })
    #expect(byDay == [1: loire, 2: loire, 3: loire, 4: paris])
    // The seeded day-9 orphan and the old day-3 Paris row are gone.
    #expect(rows.count == 4)
  }

  @Test("replaceAssignments with an empty layout clears every day")
  func replaceAssignmentsEmptyClearsAll() async throws {
    let loire = UUID()
    let remaining = try await database.write { db -> Int in
      let trip = try Trip.create(name: "France", lengthInDays: 4, in: db)
      try TripDayRegion.setRegion(loire, forTrip: trip.id, day: 1, in: db)
      try TripDayRegion.replaceAssignments([:], forTrip: trip.id, in: db)
      return try TripDayRegion.where { $0.tripID.eq(trip.id) }.fetchAll(db).count
    }
    #expect(remaining == 0)
  }

  @Test("replaceAssignments touches only its own trip")
  func replaceAssignmentsScopedToTrip() async throws {
    let loire = UUID()
    let otherRegionCount = try await database.write { db -> Int in
      let france = try Trip.create(name: "France", lengthInDays: 4, in: db)
      let italy = try Trip.create(name: "Italy", lengthInDays: 4, in: db)
      try TripDayRegion.setRegion(loire, forTrip: italy.id, day: 1, in: db)
      try TripDayRegion.replaceAssignments([1: loire], forTrip: france.id, in: db)
      return try TripDayRegion.where { $0.tripID.eq(italy.id) }.fetchAll(db).count
    }
    #expect(otherRegionCount == 1)
  }

  @Test("setLength updates the duration and clamps to at least one day")
  func setLengthUpdatesAndClamps() async throws {
    let (shortened, clamped) = try await database.write { db -> (Int, Int) in
      let trip = try Trip.create(name: "France", lengthInDays: 7, in: db)
      try Trip.setLength(3, tripID: trip.id, in: db)
      let shortened = try Trip.find(trip.id).fetchOne(db)!.lengthInDays
      try Trip.setLength(0, tripID: trip.id, in: db)
      let clamped = try Trip.find(trip.id).fetchOne(db)!.lengthInDays
      return (shortened, clamped)
    }
    #expect(shortened == 3)
    #expect(clamped == 1)
  }
}
