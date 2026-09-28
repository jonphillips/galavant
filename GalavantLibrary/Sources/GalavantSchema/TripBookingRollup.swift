import Foundation

/// A trip-row identity, keeping booking decisions scoped to individual ring members.
public enum TripBookingRow: Hashable, Sendable {
  case stop(TripIdea.ID)
  case stay(TripStay.ID)
}

public struct TripBookingItem: Equatable, Sendable {
  public let row: TripBookingRow
  public let title: String
  public let day: Int?
  public let sortTime: Int
  /// An exact local time when this item has one; nil for daypart and all-day rows.
  public let time: String?
  public let bookingURL: String?
  public let confirmationNumber: String?
  public let booking: ResolvedBooking

  public init(
    row: TripBookingRow,
    title: String,
    day: Int?,
    sortTime: Int,
    time: String?,
    bookingURL: String?,
    confirmationNumber: String?,
    booking: ResolvedBooking
  ) {
    self.row = row
    self.title = title
    self.day = day
    self.sortTime = sortTime
    self.time = time
    self.bookingURL = bookingURL
    self.confirmationNumber = confirmationNumber
    self.booking = booking
  }
}

/// One-pass booking sections for the itinerary and stays in a trip plan (ADR-0047 §3).
public struct TripBookingRollup: Equatable, Sendable {
  public let toBook: [TripBookingItem]
  public let decide: [TripBookingItem]
  public let booked: [TripBookingItem]
  /// Every scheduled stop and stay's resolved booking, including rows that the
  /// actionable sections omit because they are past, complete, or skipped.
  public let items: [TripBookingItem]
  public var toBookCount: Int { toBook.count }

  public init(plan: TripPlan, currentDay: Int?) {
    var toBook: [TripBookingItem] = []
    var decide: [TripBookingItem] = []
    var booked: [TripBookingItem] = []
    var items: [TripBookingItem] = []

    for stop in plan.scheduled {
      let entry = stop.entry
      let booking = entry.resolvedBooking(idea: stop.idea)
      let item = TripBookingItem(
        row: .stop(entry.id),
        title: stop.content.title,
        day: entry.dayNumber,
        sortTime: entry.schedule.intraDaySort,
        time: entry.schedule.bookingTime,
        bookingURL: Self.effectiveURL(rowURL: entry.bookingURL, ideaURL: stop.idea?.url),
        confirmationNumber: entry.confirmationNumber,
        booking: booking)
      items.append(item)
      guard entry.completedAt == nil, entry.skippedAt == nil else { continue }
      if let currentDay, let day = entry.dayNumber, day < currentDay { continue }
      Self.append(item, to: &toBook, decide: &decide, booked: &booked)
    }

    for stay in plan.stays {
      let row = stay.stay
      let item = TripBookingItem(
        row: .stay(row.id),
        title: stay.content.title,
        day: row.checkInDay,
        sortTime: row.checkInSortMinutes,
        time: row.plannedCheckInTime ?? row.checkInTime,
        bookingURL: Self.effectiveURL(rowURL: row.bookingURL, ideaURL: stay.idea?.url),
        confirmationNumber: row.confirmationNumber,
        booking: row.resolvedBooking)
      items.append(item)
      // A stay remains actionable through its check-out day; only after that day
      // passes does it leave the to-book, decide, and booked sections.
      guard currentDay.map({ row.checkOutDay >= $0 }) ?? true else { continue }
      Self.append(item, to: &toBook, decide: &decide, booked: &booked)
    }

    self.toBook = Self.sorted(toBook)
    self.decide = Self.sorted(decide)
    self.booked = Self.sorted(booked)
    self.items = items
  }

  private static func append(
    _ item: TripBookingItem,
    to toBook: inout [TripBookingItem],
    decide: inout [TripBookingItem],
    booked: inout [TripBookingItem]
  ) {
    switch item.booking.status {
    case .some(.toBook): toBook.append(item)
    case .some(.booked): booked.append(item)
    case .some(.notNeeded): break
    case .none: decide.append(item)
    }
  }

  private static func sorted(_ items: [TripBookingItem]) -> [TripBookingItem] {
    items.sorted { lhs, rhs in
      guard let leftDay = lhs.day else { return rhs.day == nil && lhs.sortTime < rhs.sortTime }
      guard let rightDay = rhs.day else { return true }
      if leftDay != rightDay { return leftDay < rightDay }
      return lhs.sortTime < rhs.sortTime
    }
  }

  private static func effectiveURL(rowURL: String?, ideaURL: String?) -> String? {
    if let rowURL, !rowURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return rowURL
    }
    guard let ideaURL, !ideaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return ideaURL
  }
}

private extension Schedule {
  var bookingTime: String? {
    guard case let .timed(_, start, _) = self else { return nil }
    return start
  }
}
