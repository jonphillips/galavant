import Foundation
import GalavantSchema
import Testing

@Suite struct BookingReminderPlanTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func reminderUsesLeadTimeAndOpeningCopy() {
    let candidate = candidate("Kikunoi", opensAt: now.addingTimeInterval(60 * 60))
    let result = desired([candidate])
    #expect(result.count == 1)
    #expect(result[0].fireAt == now.addingTimeInterval(30 * 60))
    #expect(result[0].title.contains("Kikunoi"))
    #expect(result[0].body.contains("opens"))
  }

  @Test func openingInsideLeadWindowFiresNowAndPassedOpeningIsDropped() {
    let inside = candidate("Inside", opensAt: now.addingTimeInterval(10 * 60))
    let past = candidate("Past", opensAt: now.addingTimeInterval(-1))
    let result = desired([inside, past])
    #expect(result.map(\.fireAt) == [now])
    #expect(result.map(\.title).contains { $0.contains("Inside") })
  }

  @Test func nearestLimitIsKept() {
    let candidates = (1...3).map { candidate("\($0)", opensAt: now.addingTimeInterval(Double($0) * 3_600)) }
    let result = desired(candidates, limit: 2)
    #expect(result.count == 2)
    #expect(result[0].fireAt == now.addingTimeInterval(30 * 60))
    #expect(result[1].fireAt == now.addingTimeInterval(90 * 60))
  }

  @Test func diffRemovesBookedAndReplacesMovedOpening() {
    let stopID = UUID()
    let old = candidate("Moved", opensAt: now.addingTimeInterval(3_600), stopID: stopID)
    let moved = candidate("Moved", opensAt: now.addingTimeInterval(7_200), stopID: stopID)
    let booked = candidate("Booked", opensAt: now.addingTimeInterval(3_600), status: .booked)
    let oldRequest = desired([old, booked])
    let newRequest = desired([moved])
    let diff = BookingReminderPlan.diff(desired: newRequest, pending: oldRequest)
    let reminderID = "booking-opens.\(stopID.uuidString)"
    #expect(diff.remove == [reminderID])
    #expect(diff.add.map(\.id) == [reminderID])
    if case let .opensLater(opensAt) = moved.item.opening {
      #expect(diff.add[0].opensAt == opensAt)
    } else {
      Issue.record("Expected the moved opening to remain scheduled")
    }
  }

  @Test func alreadyScheduledInsideWindowIsNotAddedAgain() {
    let stopID = UUID()
    let opening = now.addingTimeInterval(10 * 60)
    let candidate = candidate("Inside", opensAt: opening, stopID: stopID)
    let key = BookingReminderKey(id: "booking-opens.\(stopID.uuidString)", opensAt: opening)
    #expect(desired([candidate], notified: [key]).isEmpty)
  }

  @Test func reminderCopyUsesLeadAndStableLocaleInputs() {
    let candidate = candidate("Kikunoi", opensAt: now.addingTimeInterval(90 * 60), timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    let result = desired([candidate], lead: .seconds(2_700), deviceTimeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US"))
    #expect(result[0].title == "Booking opens in 45 min · Kikunoi")
    guard case .opensLater = candidate.item.opening else {
      Issue.record("Expected a future opening")
      return
    }
    #expect(result[0].body == "Dinner Fri, Jan 15 · opens 6:30 PM GMT+9 · Kyoto")
  }

  private func candidate(
    _ title: String, opensAt: Date, status: BookingStatus = .toBook,
    stopID: UUID = UUID(), timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!
  ) -> BookingReminderCandidate {
    let item = TripBookingItem(
      row: .stop(stopID), title: title, day: 2, sortTime: 720, time: nil, bookingURL: nil,
      confirmationNumber: nil, booking: ResolvedBooking(status: status, source: .explicit),
      opening: status == .toBook ? .opensLater(opensAt) : nil)
    return BookingReminderCandidate(
      item: item, tripID: UUID(), tripName: "Kyoto", mealDate: now, timeZone: timeZone)
  }

  private func desired(
    _ candidates: [BookingReminderCandidate], lead: Duration = .seconds(1_800), limit: Int = 50,
    notified: Set<BookingReminderKey> = [], deviceTimeZone: TimeZone = TimeZone(secondsFromGMT: 0)!,
    locale: Locale = Locale(identifier: "en_US")
  ) -> [BookingReminder] {
    BookingReminderPlan.desired(
      candidates: candidates, now: now, lead: lead, limit: limit, notified: notified,
      deviceTimeZone: deviceTimeZone, locale: locale)
  }
}
