import Dependencies
import Foundation
import GalavantSchema
@preconcurrency import UserNotifications

struct BookingReminderClient {
  var authorize: @MainActor @Sendable () async -> Bool
  var pendingIdentifiers: @MainActor @Sendable () async -> [String]
  var pending: @MainActor @Sendable () async -> [BookingReminder]
  var add: @MainActor @Sendable (BookingReminder) async throws -> Void
  var remove: @MainActor @Sendable ([String]) async -> Void
}

private enum BookingReminderClientKey: DependencyKey {
  static let liveValue = BookingReminderClient(
    authorize: { await authorizeNotifications() },
    pendingIdentifiers: { await pendingIdentifiers() },
    pending: { await pendingReminders() },
    add: { try await addReminder($0) },
    remove: { removeReminders($0) })

  static let testValue = BookingReminderClient(
    authorize: { false }, pendingIdentifiers: { [] }, pending: { [] }, add: { _ in }, remove: { _ in })

  @MainActor private static func authorizeNotifications() async -> Bool {
    let center = UNUserNotificationCenter.current()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      center.getNotificationSettings { settings in
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
          continuation.resume(returning: true)
        } else if settings.authorizationStatus == .notDetermined {
          center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            continuation.resume(returning: granted)
          }
        } else {
          continuation.resume(returning: false)
        }
      }
    }
  }

  @MainActor private static func pendingReminders() async -> [BookingReminder] {
    let center = UNUserNotificationCenter.current()
    return await withCheckedContinuation { (continuation: CheckedContinuation<[BookingReminder], Never>) in
      center.getPendingNotificationRequests { requests in
        let reminders = requests.compactMap { request -> BookingReminder? in
          guard request.identifier.hasPrefix("booking-opens."),
            let opensAtSeconds = (request.content.userInfo["opensAt"] as? NSNumber)?.doubleValue,
            let fireAtSeconds = (request.content.userInfo["fireAt"] as? NSNumber)?.doubleValue,
            let trip = request.content.userInfo["tripID"] as? String,
            let tripID = UUID(uuidString: trip)
          else { return nil }
          return BookingReminder(
            id: request.identifier, opensAt: Date(timeIntervalSince1970: opensAtSeconds),
            fireAt: Date(timeIntervalSince1970: fireAtSeconds), deliverImmediately: request.trigger == nil,
            title: request.content.title,
            body: request.content.body, tripID: tripID)
        }
        continuation.resume(returning: reminders)
      }
    }
  }

  @MainActor private static func pendingIdentifiers() async -> [String] {
    let center = UNUserNotificationCenter.current()
    return await withCheckedContinuation { continuation in
      center.getPendingNotificationRequests { requests in
        continuation.resume(returning: requests.map(\.identifier).filter { $0.hasPrefix("booking-opens.") })
      }
    }
  }

  @MainActor private static func addReminder(_ reminder: BookingReminder) async throws {
    let center = UNUserNotificationCenter.current()
    let content = UNMutableNotificationContent()
    content.title = reminder.title
    content.body = reminder.body
    content.sound = .default
    content.userInfo = ["tripID": reminder.tripID.uuidString]
    content.userInfo["opensAt"] = reminder.opensAt.timeIntervalSince1970
    content.userInfo["fireAt"] = reminder.fireAt.timeIntervalSince1970
    let trigger = bookingReminderTrigger(for: reminder)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  @MainActor private static func removeReminders(_ identifiers: [String]) {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
  }
}

func bookingReminderTrigger(for reminder: BookingReminder) -> UNNotificationTrigger? {
  guard !reminder.deliverImmediately else { return nil }
  var calendar = Calendar(identifier: .gregorian)
  let utc = TimeZone(secondsFromGMT: 0)!
  calendar.timeZone = utc
  var components = calendar.dateComponents(
    [.year, .month, .day, .hour, .minute, .second], from: reminder.fireAt)
  components.calendar = calendar
  components.timeZone = utc
  return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
}

extension DependencyValues {
  var bookingReminderClient: BookingReminderClient {
    get { self[BookingReminderClientKey.self] }
    set { self[BookingReminderClientKey.self] = newValue }
  }
}
