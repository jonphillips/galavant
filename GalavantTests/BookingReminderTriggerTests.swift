import Foundation
import GalavantSchema
import Testing
import UserNotifications
@testable import Galavant

@Suite struct BookingReminderTriggerTests {
  @Test func calendarTriggerPreservesUTCInstant() {
    let fireAt = Date(timeIntervalSince1970: 1_800_000_000)
    let reminder = BookingReminder(
      id: "booking-opens.\(UUID().uuidString)", opensAt: fireAt.addingTimeInterval(1_800),
      fireAt: fireAt, deliverImmediately: false, title: "Booking opens", body: "Dinner", tripID: UUID())
    let trigger = bookingReminderTrigger(for: reminder) as? UNCalendarNotificationTrigger
    #expect(trigger?.nextTriggerDate() == fireAt)
  }
}
