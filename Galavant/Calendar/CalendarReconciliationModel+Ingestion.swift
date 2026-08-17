import Foundation
import GalavantPlaces
import GalavantSchema
import SQLiteData

extension CalendarReconciliationModel {
  /// A missing device-local EventKit identifier is necessary but insufficient
  /// deletion evidence because sync may replace that identifier. A healthy
  /// full-access read therefore corroborates absence through the event's server
  /// identity before a Calendar-originated constraint is removed. A missing
  /// recurring occurrence stays unknown while its series remains visible.
  func deletedConstraintEventIDs(
    observedEvents: [CalendarObservedEvent],
    selectedCalendarID: String
  ) -> Set<String> {
    Set(localState.linkedConstraints.compactMap { binding in
      guard binding.calendarID == selectedCalendarID,
        !observedEvents.contains(where: binding.matches),
        calendarClient.event(binding.eventID) == nil
      else { return nil }
      let serverMatches = calendarClient.eventsWithExternalIdentifier(
        binding.sourceExternalIdentifier)
      guard !serverMatches.contains(where: binding.matches),
        !calendarClient.hasCalendarItemsWithExternalIdentifier(binding.sourceExternalIdentifier)
      else { return nil }
      return binding.eventID
    })
  }

  /// A Calendar-originated constraint confirmed outside the trip drops its shared
  /// row but retains the local binding, ready to recreate if the event comes back.
  func movedOutsideConstraintEventIDs(
    selectedCalendarID: String,
    temporalContext: CalendarTripTemporalContext,
    regionTimeZone: TimeZone?
  ) -> Set<String> {
    Set(localState.linkedConstraints.compactMap { binding in
      guard binding.calendarID == selectedCalendarID,
        let event = calendarClient.event(binding.eventID),
        temporalContext.project(event.temporal, absoluteTimeZone: regionTimeZone) == .outsideTrip
      else { return nil }
      return binding.eventID
    })
  }

  func ingest(
    _ events: [CalendarObservedEvent],
    regionTimeZone: TimeZone?
  ) async throws -> [CalendarIngestedEvent] {
    var ingested: [CalendarIngestedEvent] = []
    for event in events {
      try Task.checkCancellation()
      let match = await placeMatcher.match(
        calendarEventTitle: event.title, latitude: event.latitude,
        longitude: event.longitude, location: event.location)
      let matchedPlace = match.map {
        CalendarMatchedPlace(name: $0.name ?? event.title, mapItemIdentifier: $0.mapItemIdentifier)
      }
      // Destination zone wins; a venue zone is only the region-less fallback.
      let itineraryTimeZone = regionTimeZone
        ?? match?.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
      ingested.append(CalendarIngestedEvent(
        event: event, matchedPlace: matchedPlace, itineraryTimeZone: itineraryTimeZone))
    }
    return ingested
  }

  func regionTimeZone(for trip: Trip, plan: TripPlan? = nil) async -> TimeZone? {
    let regions = (try? await database.read { db -> [MapRegion] in
      let ids = try TripRegion.regionIDs(forTrip: trip.id, in: db)
      return try MapRegion.where { $0.id.in(ids) }.fetchAll(db)
    }) ?? []
    if let box = MapRegion.boundingBox(of: regions) {
      return await placeMatcher.timeZone(
        latitude: box.centerLatitude, longitude: box.centerLongitude)
    }
    let coordinates: [(latitude: Double, longitude: Double)] = plan?.itinerary.flatMap(\.stops).compactMap {
      guard let latitude = $0.content.latitude, let longitude = $0.content.longitude else {
        return nil
      }
      return (latitude: latitude, longitude: longitude)
    } ?? []
    guard !coordinates.isEmpty else { return nil }
    let latitude = coordinates.map(\.0).reduce(0, +) / Double(coordinates.count)
    let longitude = coordinates.map(\.1).reduce(0, +) / Double(coordinates.count)
    return await placeMatcher.timeZone(latitude: latitude, longitude: longitude)
  }

  func dayTimeZones(for trip: Trip, centroid: TimeZone?) async -> [DayNumber: TimeZone] {
    let facts = (try? await database.read { db -> (
      overrides: [TripDayTimeZone], assignments: [TripDayRegion], regions: [MapRegion]
    ) in
      let assignments = try TripDayRegion.where { $0.tripID.eq(trip.id) }.fetchAll(db)
      let regionIDs = assignments.map(\.regionID)
      let regions = regionIDs.isEmpty
        ? []
        : try MapRegion.where { $0.id.in(regionIDs) }.fetchAll(db)
      return (
        overrides: try TripDayTimeZone.where { $0.tripID.eq(trip.id) }.fetchAll(db),
        assignments: assignments,
        regions: regions)
    }) ?? (overrides: [], assignments: [], regions: [])

    let regionsByID = Dictionary(facts.regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let overridesByDay = Dictionary(
      facts.overrides.compactMap { row in
        row.timeZoneIdentifier.map { (row.dayNumber, $0) }
      }, uniquingKeysWith: { first, _ in first })
    var result: [DayNumber: TimeZone] = [:]
    for assignment in facts.assignments {
      let regionZone: TimeZone?
      if let region = regionsByID[assignment.regionID] {
        regionZone = await placeMatcher.timeZone(
          latitude: region.centerLatitude, longitude: region.centerLongitude)
      } else {
        regionZone = nil
      }
      let override = overridesByDay[assignment.dayNumber].flatMap(TimeZone.init(identifier:))
      if let resolved = CalendarTripTimeZoneResolver.resolve(
        dayOverride: override, dayRegion: regionZone, tripCentroid: centroid) {
        result[assignment.dayNumber] = resolved
      }
    }
    for (day, identifier) in overridesByDay where result[day] == nil {
      if let timeZone = TimeZone(identifier: identifier) {
        result[day] = timeZone
      }
    }
    return result
  }

  func scope(for trip: Trip, calendar: Calendar) -> CalendarTripScope? {
    guard let startDate = trip.startDate else { return nil }
    return CalendarTripScope(
      start: CalendarCivilDate(startDate, calendar: calendar), dayCount: trip.lengthInDays)
  }

  static let storageTimeZone = TimeZone(secondsFromGMT: 0)!
}
