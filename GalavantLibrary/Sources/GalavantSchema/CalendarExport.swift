import Foundation

/// One scheduled stop's calendar-event projection (BACKLOG "Export itinerary to
/// Apple Calendar / iCal"). Pure and DB-free — an `EKEvent`'s worth of fields,
/// with no EventKit type in sight, so the derivation is testable without a
/// calendar database. The **app target**'s injectable EventKit client
/// (`CalendarExportClient`) is the only thing that ever turns one of these into
/// a real event; this stays a value.
///
/// Identity mapping for re-export reconciliation is by `id` (the `TripIdea`),
/// stored **locally only** (`CalendarExportIdentityStore`, `UserDefaults`) —
/// never synced through CloudKit. EventKit identifiers are meaningful only on
/// the device that created them (the settled one-way, per-device mirror design:
/// Galavant writes, nothing reads back, no shared calendar).
public struct CalendarExportItem: Identifiable, Equatable, Sendable {
  public var id: TripIdea.ID
  public var title: String
  public var notes: String?
  public var start: Date
  public var end: Date
  public var isAllDay: Bool

  public init(
    id: TripIdea.ID, title: String, notes: String?, start: Date, end: Date, isAllDay: Bool
  ) {
    self.id = id
    self.title = title
    self.notes = notes
    self.start = start
    self.end = end
    self.isAllDay = isAllDay
  }
}

extension TripPlan {
  /// Default block length for a `.daypart` stop's synthesized event, in
  /// minutes — a daypart carries no stored end, so the export gives it a
  /// representative span (2 hours) rather than a zero-length event.
  public static let daypartExportDurationMinutes = 120

  /// This trip's itinerary as calendar-export items, in itinerary order — one
  /// per exportable scheduled stop. Empty for an undated trip (nothing to
  /// export, BACKLOG) or a trip with no scheduled stops. Pure: `trip.startDate`
  /// (via `Trip.date(forDay:)`) plus this plan's `itinerary` in, export items
  /// out — no EventKit, no I/O.
  public func calendarExportItems(trip: Trip) -> [CalendarExportItem] {
    guard trip.startDate != nil else { return [] }
    let calendar = Calendar.current
    return itinerary.flatMap { day -> [CalendarExportItem] in
      guard let dayStart = trip.date(forDay: day.number) else { return [] }
      return day.stops.compactMap { Self.exportItem(for: $0, dayStart: dayStart, calendar: calendar) }
    }
  }

  /// One stop's export item, or nil for a schedule this projection can't place
  /// (`.unscheduled` shouldn't reach here — `itinerary` only yields scheduled,
  /// day-placed stops — or a malformed `.timed` start `Schedule.minutes(from:)`
  /// can't parse).
  ///
  /// - `.day` → an all-day event spanning the calendar day (start = midnight,
  ///   end = the next midnight — `EKEvent`'s all-day convention).
  /// - `.daypart` → a timed event anchored at `DayPart.sortHour` (the same
  ///   representative hour the itinerary already sorts by), synthesized to
  ///   `daypartExportDurationMinutes` long.
  /// - `.timed` → the exact clock start; the exact end when the stop has one,
  ///   else `Schedule.suggestedGapMinutes` after the start (the same "assumed
  ///   single-stop duration" ADR-0033's suggested-time math already uses).
  static func exportItem(
    for stop: ResolvedStop, dayStart: Date, calendar: Calendar
  ) -> CalendarExportItem? {
    let title = stop.content.title
    let notes = exportNotes(for: stop.content)
    switch stop.entry.schedule {
    case .unscheduled:
      return nil
    case .day:
      let start = calendar.startOfDay(for: dayStart)
      guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
      return CalendarExportItem(id: stop.id, title: title, notes: notes, start: start, end: end, isAllDay: true)
    case let .daypart(_, part):
      guard let start = calendar.date(bySettingHour: part.sortHour, minute: 0, second: 0, of: dayStart)
      else { return nil }
      let end = calendar.date(byAdding: .minute, value: daypartExportDurationMinutes, to: start) ?? start
      return CalendarExportItem(id: stop.id, title: title, notes: notes, start: start, end: end, isAllDay: false)
    case let .timed(_, startTime, endTime):
      let dayFloor = calendar.startOfDay(for: dayStart)
      guard let startMinutes = Schedule.minutes(from: startTime),
        let start = calendar.date(byAdding: .minute, value: startMinutes, to: dayFloor)
      else { return nil }
      let end: Date
      if let endTime, let endMinutes = Schedule.minutes(from: endTime),
        let explicitEnd = calendar.date(byAdding: .minute, value: endMinutes, to: dayFloor),
        explicitEnd > start {
        end = explicitEnd
      } else {
        end = calendar.date(byAdding: .minute, value: Schedule.suggestedGapMinutes, to: start) ?? start
      }
      return CalendarExportItem(id: stop.id, title: title, notes: notes, start: start, end: end, isAllDay: false)
    }
  }

  /// The event's notes body: an idea-backed stop prefers its user notes, falling
  /// back to its description; a freeform stop uses its inline note. Nil (no
  /// notes field on the event) when there's nothing to show.
  private static func exportNotes(for content: StopContent) -> String? {
    switch content {
    case let .idea(idea):
      let text = idea.notes.isEmpty ? idea.description : idea.notes
      return text.isEmpty ? nil : text
    case let .freeform(_, note):
      return note
    }
  }
}
