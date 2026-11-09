import Foundation
import SQLiteData

/// A move of one day to another position in a trip's day sequence.
public struct DayMove: Equatable, Sendable {
  public var from: Int
  public var to: Int

  public init(from: Int, to: Int) {
    self.from = from
    self.to = to
  }

  /// Old day → new day, for every day whose position changes.
  public func mapping() -> [Int: Int] {
    guard from != to else { return [:] }
    return Dictionary(uniqueKeysWithValues: affectedDays.compactMap { day in
      guard day != from else { return (day, to) }
      return (day, from < to ? day - 1 : day + 1)
    })
  }

  public var affectedDays: ClosedRange<Int> { min(from, to)...max(from, to) }

  public func validate(locks: [Int: DayLock], dayLabel: (Int) -> String) -> DayMoveRefusal? {
    guard from != to else { return nil }
    for day in affectedDays {
      guard let lock = locks[day] else { continue }
      return .locked(day: day, label: dayLabel(day), lock)
    }
    return nil
  }
}

public enum DayLock: Equatable, Sendable {
  case booking(title: String)
  case past

  var reason: String {
    switch self {
    case let .booking(title): "has a booking: \(title)"
    case .past: "has already happened"
    }
  }
}

public enum DayMoveRefusal: Equatable, Sendable, LocalizedError {
  case locked(day: Int, label: String, DayLock)

  public var errorDescription: String? {
    switch self {
    case let .locked(_, label, lock): "\(label) \(lock.reason)"
    }
  }
}

extension Trip {
  /// Move the day and its design data as one transaction. Stops retain their
  /// stable ids, so the calendar export reconciliation moves their existing events.
  public static func moveDay(
    _ move: DayMove,
    tripID: Trip.ID,
    now: Date,
    in db: Database
  ) throws {
    guard move.from != move.to else { return }
    guard let trip = try Trip.find(tripID).fetchOne(db) else { throw TripError.creationFailed }
    guard (1...trip.lengthInDays).contains(move.from),
      (1...trip.lengthInDays).contains(move.to)
    else { return }

    let stops = try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db)
    let ideas = try Idea.all.fetchAll(db)
    let stopsByDay = Dictionary(grouping: stops.compactMap { stop -> (Int, ResolvedStop)? in
      guard let day = stop.dayNumber else { return nil }
      let content: StopContent
      if let ideaID = stop.ideaID, let idea = ideas.first(where: { $0.id == ideaID }) {
        content = .idea(idea)
      } else if let title = stop.inlineTitle {
        content = .freeform(title: title, note: stop.inlineNote, coordinate: nil)
      } else {
        content = .freeform(title: "Unknown stop", note: nil, coordinate: nil)
      }
      return (day, ResolvedStop(entry: stop, content: content))
    }, by: \.0)
    let resolvedStops = stopsByDay.values.flatMap { $0.map(\.1) }
    let dayRegions = try TripDayRegion.where { $0.tripID.eq(tripID) }.fetchAll(db)
    let dayTimeZones = try TripDayTimeZone.where { $0.tripID.eq(tripID) }.fetchAll(db)
    let dayNotes = try TripDayNote.where { $0.tripID.eq(tripID) }.fetchAll(db)
    let designs = TripDayDesign.rows(
      trip: trip,
      dayRegions: dayRegions,
      dayTimeZones: dayTimeZones,
      dayNotes: dayNotes,
      stays: [],
      stops: resolvedStops,
      now: now)
    let locks = Dictionary(uniqueKeysWithValues: designs.compactMap { design in
      design.lock.map { (design.day, $0) }
    })
    if let refusal = move.validate(locks: locks, dayLabel: { day in
      guard let date = trip.date(forDay: day) else { return "Day \(day)" }
      return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }) {
      throw refusal
    }

    let mapping = move.mapping()
    for stop in stops where mapping[stop.dayNumber ?? 0] != nil {
      guard let oldDay = stop.dayNumber, let newDay = mapping[oldDay] else { continue }
      try TripIdea.find(stop.id).update { $0.dayNumber = #bind(newDay) }.execute(db)
    }
    for region in dayRegions where mapping[region.dayNumber] != nil {
      guard let day = mapping[region.dayNumber] else { continue }
      try TripDayRegion.find(region.id).update { $0.dayNumber = #bind(day) }.execute(db)
    }

    try moveDesignRows(
      mapping: mapping, tripID: tripID, notes: dayNotes, timeZones: dayTimeZones, in: db)
  }

  private static func moveDesignRows(
    mapping: [Int: Int], tripID: Trip.ID, notes: [TripDayNote],
    timeZones: [TripDayTimeZone], in db: Database
  ) throws {
    let movedNotes = notes.filter { mapping[$0.dayNumber] != nil }
    for note in movedNotes { try TripDayNote.find(note.id).delete().execute(db) }
    for note in movedNotes {
      guard let day = mapping[note.dayNumber] else { continue }
      try TripDayNote.set(note.note, forTrip: tripID, day: day, in: db)
    }

    let movedZones = timeZones.filter { mapping[$0.dayNumber] != nil }
    for zone in movedZones { try TripDayTimeZone.find(zone.id).delete().execute(db) }
    for zone in movedZones {
      guard let day = mapping[zone.dayNumber], let identifier = zone.timeZoneIdentifier else { continue }
      try TripDayTimeZone.set(identifier, forTrip: tripID, day: day, in: db)
    }
  }
}
