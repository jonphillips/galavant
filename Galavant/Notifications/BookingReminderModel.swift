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
  @ObservationIgnored @Shared(.appStorage("bookingRemindersNotifiedOpenings")) private var notifiedOpeningKeysRaw = "[]"
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
    let identifiers = await client.pendingIdentifiers()
    let pending = await client.pending()
    guard enabled else {
      await client.remove(identifiers)
      return
    }
    do {
      let snapshot = try await loadSnapshot()
      let moment = now
      let matcher = placeMatcher
      let candidates = await Self.candidates(in: snapshot, now: moment, matcher: matcher)
      var notified = notifiedKeys()
      notified = Set(notified.filter { $0.opensAt > moment })
      $notifiedOpeningKeysRaw.withLock { $0 = Self.encoded(notified) }
      let pendingKeys = Set(pending.map { BookingReminderKey(id: $0.id, opensAt: $0.opensAt) })
      let alreadyScheduled = notified.subtracting(pendingKeys)
      let desired = BookingReminderPlan.desired(
        candidates: candidates, now: moment, notified: alreadyScheduled,
        deviceTimeZone: .current, locale: .current)
      let changes = BookingReminderPlan.diff(desired: desired, pending: pending)
      let unparsed = Set(identifiers).subtracting(pending.map(\.id))
      await client.remove(changes.remove + Array(unparsed))
      for reminder in changes.add {
        do {
          try await client.add(reminder)
          notified.insert(BookingReminderKey(id: reminder.id, opensAt: reminder.opensAt))
          $notifiedOpeningKeysRaw.withLock { $0 = Self.encoded(notified) }
        }
        catch { reportIssue("Booking reminder could not be scheduled: \(error)") }
      }
    } catch {
      reportIssue("Booking reminders could not be reconciled: \(error)")
    }
  }

  private func notifiedKeys() -> Set<BookingReminderKey> {
    guard let data = notifiedOpeningKeysRaw.data(using: .utf8),
      let keys = try? JSONDecoder().decode([BookingReminderKey].self, from: data)
    else { return [] }
    return Set(keys)
  }

  private static func encoded(_ keys: Set<BookingReminderKey>) -> String {
    guard let data = try? JSONEncoder().encode(keys.sorted {
      if $0.id != $1.id { return $0.id < $1.id }
      return $0.opensAt < $1.opensAt
    }), let value = String(data: data, encoding: .utf8) else { return "[]" }
    return value
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
    let ideasByID = Dictionary(snapshot.ideas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let regionsByID = Dictionary(snapshot.regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for trip in snapshot.trips {
      let plan = TripPlan(
        entries: snapshot.entries.filter { $0.tripID == trip.id },
        ideasByID: ideasByID,
        lengthInDays: trip.lengthInDays,
        tripStays: snapshot.stays.filter { $0.tripID == trip.id },
        dayRegions: snapshot.dayRegions.filter { $0.tripID == trip.id },
        regionsByID: regionsByID,
        calendarConstraints: snapshot.constraints.filter { $0.tripID == trip.id },
        alternativeGroups: snapshot.groups.filter { $0.tripID == trip.id })
      let rollup = TripBookingRollup(
        plan: plan, currentDay: Self.currentDay(for: trip, now: now), now: now)
      let futureItems = rollup.opensLater.filter { item in
        guard case let .opensLater(opensAt) = item.opening else { return false }
        return opensAt > now
      }
      guard !futureItems.isEmpty else { continue }
      let zones = await TripDayTimeZoneResolution.resolve(
        trip: trip, plan: plan,
        tripRegions: {
          let ids = Set(snapshot.tripRegions.filter { $0.tripID == trip.id }.map(\.regionID))
          return snapshot.regions.filter { ids.contains($0.id) }
        }(),
        assignments: snapshot.dayRegions, overrides: snapshot.timeZones, regions: snapshot.regions,
        timeZoneAt: { latitude, longitude in await matcher.timeZone(latitude: latitude, longitude: longitude) })
      result += futureItems.map { item in
        let day = item.day
        let zone = day.flatMap { zones[$0] } ?? .current
        let mealDate = trip.startDate.flatMap { start in day.flatMap { TodayProjection.startOfTripDay($0, tripStartDate: start) } }
        return BookingReminderCandidate(
          item: item, tripID: trip.id, tripName: trip.name,
          mealDate: mealDate, timeZone: zone)
      }
    }
    return result
  }

  nonisolated private static func currentDay(for trip: Trip, now: Date) -> Int? {
    guard let startDate = trip.startDate else { return nil }
    return TodayProjection.tripDay(containing: now, tripStartDate: startDate, lengthInDays: trip.lengthInDays)
  }
}
