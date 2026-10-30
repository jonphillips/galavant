import Dependencies
import Foundation
import GalavantPlaces
import GalavantSchema
import SQLiteData

/// Runs the one-time completed-trip feedback pass when shared data is settled.
@MainActor
@Observable
final class VisitedRollupModel {
  /// UTC+14 to UTC−12 is the widest civil offset gap: 26 hours. Looking ahead
  /// by that amount avoids geocoding trips that cannot yet be past in any zone.
  private static let maximumTimeZoneOffsetDifference: TimeInterval = 26 * 60 * 60

  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.defaultSyncEngine) private var syncEngine
  @ObservationIgnored @Dependency(\.placeMatcher) private var placeMatcher
  @ObservationIgnored @Dependency(\.date.now) private var now

  func run() async {
    guard isSafeToWrite else { return }
    let now = self.now
    do {
      let trips = try await database.read { db in try Trip.all.fetchAll(db) }
      for trip in trips where trip.visitedRolledUpAt == nil {
        guard trip.startDate != nil,
          trip.isPast(
            at: now.addingTimeInterval(Self.maximumTimeZoneOffsetDifference),
            calendar: .current)
        else { continue }
        let tripCalendar = await calendar(for: trip)
        guard trip.isPast(at: now, calendar: tripCalendar), isSafeToWrite else { continue }
        try await database.write { db in
          try Trip.rollUpVisited(tripID: trip.id, now: now, calendar: tripCalendar, in: db)
        }
      }
    } catch {
      reportIssue("Visited roll-up failed: \(error)")
    }
  }

  private var isSafeToWrite: Bool {
    !GalavantCloudSync.isManuallyEnabled()
      || (syncEngine.isRunning && !syncEngine.isFetchingChanges)
  }

  private func calendar(for trip: Trip) async -> Calendar {
    let tripID = trip.id
    let regions = (try? await database.read { db -> [MapRegion] in
      let regionIDs = try TripRegion.regionIDs(forTrip: tripID, in: db)
      return try MapRegion.where { $0.id.in(regionIDs) }.fetchAll(db)
    }) ?? []
    let timeZone: TimeZone?
    if let box = MapRegion.boundingBox(of: regions) {
      timeZone = await placeMatcher.timeZone(
        latitude: box.centerLatitude,
        longitude: box.centerLongitude)
    } else {
      timeZone = nil
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone ?? .current
    return calendar
  }
}
