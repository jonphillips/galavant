import Dependencies
import Foundation
import GalavantSchema
@preconcurrency import UserNotifications

struct BookingReminderClient {
  var authorize: @MainActor @Sendable () async -> Bool
  var pending: @MainActor @Sendable () async -> [BookingReminder]
  var add: @MainActor @Sendable (BookingReminder) async throws -> Void
  var remove: @MainActor @Sendable ([String]) async -> Void
}

private enum BookingReminderClientKey: DependencyKey {
  static let liveValue = BookingReminderClient(
    authorize: { await authorizeNotifications() },
    pending: { await pendingReminders() },
    add: { try await addReminder($0) },
    remove: { removeReminders($0) })

  static let testValue = BookingReminderClient(
    authorize: { false }, pending: { [] }, add: { _ in }, remove: { _ in })

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
          guard let fireAt = request.trigger.flatMap({ ($0 as? UNCalendarNotificationTrigger)?.nextTriggerDate() }),
            let trip = request.content.userInfo["tripID"] as? String,
            let tripID = UUID(uuidString: trip)
          else { return nil }
          return BookingReminder(
            id: request.identifier, fireAt: fireAt, title: request.content.title,
            body: request.content.body, tripID: tripID)
        }
        continuation.resume(returning: reminders)
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
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: reminder.fireAt)
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
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

extension DependencyValues {
  var bookingReminderClient: BookingReminderClient {
    get { self[BookingReminderClientKey.self] }
    set { self[BookingReminderClientKey.self] = newValue }
  }
}
