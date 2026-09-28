import Foundation

/// A trip-row identity, keeping booking decisions scoped to individual ring members.
public enum TripBookingRow: Equatable, Sendable {
  case stop(TripIdea.ID)
  case stay(TripStay.ID)
}

public struct TripBookingItem: Equatable, Sendable {
  public let row: TripBookingRow
  public let title: String
  public let day: Int?
  public let sortTime: Int
  public let bookingURL: String?
  public let confirmationNumber: String?
  public let booking: ResolvedBooking

  public init(
    row: TripBookingRow,
    title: String,
    day: Int?,
    sortTime: Int,
    bookingURL: String?,
    confirmationNumber: String?,
    booking: ResolvedBooking
  ) {
    self.row = row
    self.title = title
    self.day = day
    self.sortTime = sortTime
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
  public var toBookCount: Int { toBook.count }

  public init(plan: TripPlan, currentDay: Int?) {
    var toBook: [TripBookingItem] = []
    var decide: [TripBookingItem] = []
    var booked: [TripBookingItem] = []

    for stop in plan.scheduled {
      let entry = stop.entry
      guard entry.completedAt == nil, entry.skippedAt == nil else { continue }
      if let currentDay, let day = entry.dayNumber, day < currentDay { continue }
      let booking = entry.resolvedBooking(idea: stop.idea)
      let item = TripBookingItem(
        row: .stop(entry.id),
        title: stop.content.title,
        day: entry.dayNumber,
        sortTime: entry.schedule.intraDaySort,
        bookingURL: Self.effectiveURL(rowURL: entry.bookingURL, ideaURL: stop.idea?.url),
        confirmationNumber: entry.confirmationNumber,
        booking: booking)
      Self.append(item, to: &toBook, decide: &decide, booked: &booked)
    }

    for stay in plan.stays {
      guard currentDay.map({ stay.stay.checkInDay >= $0 }) ?? true else { continue }
      let row = stay.stay
      let item = TripBookingItem(
        row: .stay(row.id),
        title: stay.content.title,
        day: row.checkInDay,
        sortTime: row.checkInSortMinutes,
        bookingURL: Self.effectiveURL(rowURL: row.bookingURL, ideaURL: stay.idea?.url),
        confirmationNumber: row.confirmationNumber,
        booking: row.resolvedBooking)
      Self.append(item, to: &toBook, decide: &decide, booked: &booked)
    }

    self.toBook = Self.sorted(toBook)
    self.decide = Self.sorted(decide)
    self.booked = Self.sorted(booked)
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
