import Foundation
import GalavantSchema
import Testing

@Suite struct BookingReminderPlanTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func reminderUsesLeadTimeAndOpeningCopy() {
    let candidate = candidate("Kikunoi", opensAt: now.addingTimeInterval(60 * 60))
    let result = BookingReminderPlan.desired(candidates: [candidate], now: now)
    #expect(result.count == 1)
    #expect(result[0].fireAt == now.addingTimeInterval(30 * 60))
    #expect(result[0].title.contains("Kikunoi"))
    #expect(result[0].body.contains("opens"))
  }

  @Test func openingInsideLeadWindowFiresNowAndPassedOpeningIsDropped() {
    let inside = candidate("Inside", opensAt: now.addingTimeInterval(10 * 60))
    let past = candidate("Past", opensAt: now.addingTimeInterval(-1))
    let result = BookingReminderPlan.desired(candidates: [inside, past], now: now)
    #expect(result.map(\.fireAt) == [now])
    #expect(result.map(\.title).contains { $0.contains("Inside") })
  }

  @Test func nearestLimitIsKept() {
    let candidates = (1...3).map { candidate("\($0)", opensAt: now.addingTimeInterval(Double($0) * 3_600)) }
    let result = BookingReminderPlan.desired(candidates: candidates, now: now, limit: 2)
    #expect(result.count == 2)
    #expect(result[0].fireAt == now.addingTimeInterval(30 * 60))
    #expect(result[1].fireAt == now.addingTimeInterval(90 * 60))
  }

  @Test func diffRemovesBookedAndReplacesMovedOpening() {
    let old = candidate("Moved", opensAt: now.addingTimeInterval(3_600))
    let moved = candidate("Moved", opensAt: now.addingTimeInterval(7_200))
    let booked = candidate("Booked", opensAt: now.addingTimeInterval(3_600), status: .booked)
    let oldRequest = BookingReminderPlan.desired(candidates: [old, booked], now: now)
    let newRequest = BookingReminderPlan.desired(candidates: [moved], now: now)
    let diff = BookingReminderPlan.diff(desired: newRequest, pending: oldRequest)
    #expect(diff.remove.sorted() == oldRequest.map(\.id).sorted())
    #expect(diff.add == newRequest)
  }

  private func candidate(
    _ title: String, opensAt: Date, status: BookingStatus = .toBook
  ) -> BookingReminderCandidate {
    let item = TripBookingItem(
      row: .stop(UUID()), title: title, day: 2, sortTime: 720, time: nil, bookingURL: nil,
      confirmationNumber: nil, booking: ResolvedBooking(status: status, source: .explicit),
      opening: status == .toBook ? .opensLater(opensAt) : nil)
    return BookingReminderCandidate(
      item: item, tripID: UUID(), tripName: "Kyoto", mealDate: now, timeZone: .current)
  }
}
