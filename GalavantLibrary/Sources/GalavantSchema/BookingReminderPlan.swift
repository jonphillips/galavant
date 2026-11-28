import Foundation

/// The trip-specific context needed to turn one rollup row into a local reminder.
public struct BookingReminderCandidate: Sendable {
  public let item: TripBookingItem
  public let tripID: Trip.ID
  public let tripName: String
  public let mealDate: Date?
  public let timeZone: TimeZone

  public init(item: TripBookingItem, tripID: Trip.ID, tripName: String, mealDate: Date?, timeZone: TimeZone) {
    self.item = item
    self.tripID = tripID
    self.tripName = tripName
    self.mealDate = mealDate
    self.timeZone = timeZone
  }
}

public struct BookingReminder: Equatable, Sendable, Identifiable {
  public let id: String
  public let opensAt: Date
  public let fireAt: Date
  public let deliverImmediately: Bool
  public let title: String
  public let body: String
  public let tripID: Trip.ID

  public init(
    id: String, opensAt: Date, fireAt: Date, deliverImmediately: Bool,
    title: String, body: String, tripID: Trip.ID
  ) {
    self.id = id
    self.opensAt = opensAt
    self.fireAt = fireAt
    self.deliverImmediately = deliverImmediately
    self.title = title
    self.body = body
    self.tripID = tripID
  }
}

public enum BookingReminderPlan {
  public static func desired(
    candidates: [BookingReminderCandidate], now: Date, lead: Duration = .seconds(1_800), limit: Int = 50,
    notified: Set<BookingReminderKey> = [], deviceTimeZone: TimeZone, locale: Locale
  ) -> [BookingReminder] {
    guard limit > 0 else { return [] }
    let reminders = candidates.compactMap { candidate -> BookingReminder? in
      guard case let .opensLater(opensAt) = candidate.item.opening,
        case let .stop(stopID) = candidate.item.row,
        opensAt > now
      else { return nil }

      let leadComponents = lead.components
      let leadSeconds = Double(leadComponents.seconds) + Double(leadComponents.attoseconds) / 1e18
      let rawFireAt = max(opensAt.addingTimeInterval(-leadSeconds), now)
      let fireAt = Date(timeIntervalSince1970: floor(rawFireAt.timeIntervalSince1970))
      let key = BookingReminderKey(id: "booking-opens.\(stopID.uuidString)", opensAt: opensAt)
      guard fireAt > now || !notified.contains(key) else { return nil }
      let opening = BookingOpeningFormat.timeString(
        moment: opensAt, timeZone: candidate.timeZone, deviceTimeZone: deviceTimeZone, locale: locale)
      let meal = candidate.mealDate.map { BookingOpeningFormat.mealDate($0, timeZone: deviceTimeZone, locale: locale) }
      let timing = fireAt <= now ? "soon" : "in \(Int(leadSeconds / 60)) min"
      let title = "Booking opens \(timing) · \(candidate.item.title)"
      let body = [meal, "opens \(opening)", candidate.tripName]
        .compactMap { $0 }
        .joined(separator: " · ")
      return BookingReminder(
        id: key.id, opensAt: opensAt, fireAt: fireAt, deliverImmediately: rawFireAt <= now,
        title: title, body: body,
        tripID: candidate.tripID)
    }
    return reminders.sorted {
      if $0.fireAt != $1.fireAt { return $0.fireAt < $1.fireAt }
      return $0.id < $1.id
    }.prefix(limit).map { $0 }
  }

  public static func diff(
    desired: [BookingReminder], pending: [BookingReminder]
  ) -> (add: [BookingReminder], remove: [String]) {
    let desiredByID = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    let pendingByID = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    let remove = pendingByID.compactMap { id, old in
      guard let new = desiredByID[id], new == old else { return id }
      return nil
    }.sorted()
    let add = desiredByID.values.filter { pendingByID[$0.id] != $0 }.sorted {
      if $0.fireAt != $1.fireAt { return $0.fireAt < $1.fireAt }
      return $0.id < $1.id
    }
    return (add, remove)
  }
}

public struct BookingReminderKey: Codable, Hashable, Sendable {
  public let id: String
  public let opensAt: Date

  public init(id: String, opensAt: Date) {
    self.id = id
    self.opensAt = opensAt
  }
}
