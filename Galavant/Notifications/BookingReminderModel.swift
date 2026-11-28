import Dependencies
import Foundation
import GalavantPlaces
import GalavantSchema
import Observation
import Sharing
import SQLiteData
import SwiftUI

@MainActor
@Observable
final class BookingReminderModel {
  private struct Snapshot: Sendable {
    var trips: [Trip]
    var entries: [TripIdea]
    var ideas: [Idea]
    var stays: [TripStay]
    var dayRegions: [TripDayRegion]
    var regions: [MapRegion]
    var timeZones: [TripDayTimeZone]
    var constraints: [CalendarTripConstraint]
    var groups: [TripAlternativeGroup]
    var tripRegions: [TripRegion]
  }

  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.bookingReminderClient) private var client
  @ObservationIgnored @Dependency(\.placeMatcher) private var placeMatcher
  @ObservationIgnored @Dependency(\.date.now) private var now
  @ObservationIgnored @Shared(.appStorage("bookingRemindersEnabled")) var enabled = false
  @ObservationIgnored private var isReconciling = false
  @ObservationIgnored private var needsAnotherReconcile = false
  private(set) var permissionMessage: String?

  func setEnabled(_ enabled: Bool) async {
    permissionMessage = nil
    guard enabled else {
      $enabled.withLock { $0 = false }
      await reconcile()
      return
    }
    guard await client.authorize() else {
      $enabled.withLock { $0 = false }
      permissionMessage = "Allow notifications in iOS Settings to receive booking reminders."
      return
    }
    $enabled.withLock { $0 = true }
    await reconcile()
  }

  func reconcile() async {
    guard !isReconciling else {
      needsAnotherReconcile = true
      return
    }
    isReconciling = true
    repeat {
      needsAnotherReconcile = false
      await reconcileOnce()
    } while needsAnotherReconcile
    isReconciling = false
  }

  private func reconcileOnce() async {
    let pending = await client.pending().filter { $0.id.hasPrefix("booking-opens.") }
    guard enabled else {
      await client.remove(pending.map(\.id))
      return
    }
    do {
      let snapshot = try await loadSnapshot()
      let moment = now
      let matcher = placeMatcher
      let candidates = await Self.candidates(in: snapshot, now: moment, matcher: matcher)
      let desired = BookingReminderPlan.desired(candidates: candidates, now: moment)
      let changes = BookingReminderPlan.diff(desired: desired, pending: pending)
      await client.remove(changes.remove)
      for reminder in changes.add {
        do { try await client.add(reminder) }
        catch { reportIssue("Booking reminder could not be scheduled: \(error)") }
      }
    } catch {
      reportIssue("Booking reminders could not be reconciled: \(error)")
    }
  }

  private func loadSnapshot() async throws -> Snapshot {
    try await database.read { db in
      Snapshot(
        trips: try Trip.all.fetchAll(db), entries: try TripIdea.all.fetchAll(db),
        ideas: try Idea.all.fetchAll(db), stays: try TripStay.all.fetchAll(db),
        dayRegions: try TripDayRegion.all.fetchAll(db), regions: try MapRegion.all.fetchAll(db),
        timeZones: try TripDayTimeZone.all.fetchAll(db),
        constraints: try CalendarTripConstraint.all.fetchAll(db),
        groups: try TripAlternativeGroup.all.fetchAll(db), tripRegions: try TripRegion.all.fetchAll(db))
    }
  }

  @concurrent private static func candidates(
    in snapshot: Snapshot, now: Date, matcher: PlaceMatcher
  ) async -> [BookingReminderCandidate] {
    var result: [BookingReminderCandidate] = []
    for trip in snapshot.trips {
      let plan = TripPlan(
        entries: snapshot.entries.filter { $0.tripID == trip.id },
        ideasByID: Dictionary(snapshot.ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
        lengthInDays: trip.lengthInDays,
        tripStays: snapshot.stays.filter { $0.tripID == trip.id },
        dayRegions: snapshot.dayRegions.filter { $0.tripID == trip.id },
        regionsByID: Dictionary(snapshot.regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
        calendarConstraints: snapshot.constraints.filter { $0.tripID == trip.id },
        alternativeGroups: snapshot.groups.filter { $0.tripID == trip.id })
      let zones = await dayZones(for: trip, plan: plan, snapshot: snapshot, matcher: matcher)
      let rollup = TripBookingRollup(
        plan: plan, currentDay: Self.currentDay(for: trip, now: now, timeZone: zones[1] ?? .current), now: now)
      result += rollup.opensLater.map { item in
        let day = item.day
        let zone = day.flatMap { zones[$0] } ?? .current
        let mealDate = trip.startDate.flatMap { start in
          day.flatMap { day in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(byAdding: .day, value: day - 1, to: start)
          }
        }
        return BookingReminderCandidate(
          item: item, tripID: trip.id, tripName: trip.name,
          mealDate: mealDate, timeZone: zone)
      }
    }
    return result
  }

  @concurrent private static func dayZones(
    for trip: Trip, plan: TripPlan, snapshot: Snapshot, matcher: PlaceMatcher
  ) async -> [Int: TimeZone] {
    let assignments = snapshot.dayRegions.filter { $0.tripID == trip.id }
    let tripRegionIDs = Set(snapshot.tripRegions.filter { $0.tripID == trip.id }.map(\.regionID))
    let assignedIDs = Set(assignments.map(\.regionID))
    let tripRegions = snapshot.regions.filter { tripRegionIDs.contains($0.id) }
    let regions = Dictionary(
      snapshot.regions.filter { tripRegionIDs.contains($0.id) || assignedIDs.contains($0.id) }
        .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let center = TripDayTimeZoneResolution.centroidCoordinate(
      regions: tripRegions, fallbackCoordinates: plan.scheduledStopCoordinates)
    let centerZone: TimeZone? = if let center {
      await matcher.timeZone(latitude: center.latitude, longitude: center.longitude)
    } else { nil }
    return await TripDayTimeZoneResolution.resolve(
      days: trip.lengthInDays > 0 ? Array(1...trip.lengthInDays) : [], assignments: assignments,
      overrides: snapshot.timeZones.filter { $0.tripID == trip.id }, regionsByID: regions,
      tripCentroid: centerZone,
      timeZoneAt: { latitude, longitude in
        await matcher.timeZone(latitude: latitude, longitude: longitude)
      })
  }

  nonisolated private static func currentDay(for trip: Trip, now: Date, timeZone: TimeZone) -> Int? {
    guard let startDate = trip.startDate else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let start = calendar.startOfDay(for: startDate)
    let today = calendar.startOfDay(for: now)
    return calendar.dateComponents([.day], from: start, to: today).day.map { $0 + 1 }
  }
}
