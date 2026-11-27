import Foundation
import GalavantSchema
import Testing

struct BookingOpeningTests {
  @Test func classifiesToBookRestaurantsAndOtherKinds() {
    let now = Date(timeIntervalSince1970: 100)
    let toBook = ResolvedBooking(status: .toBook, source: .explicit)

    #expect(BookingOpening.classify(resolved: toBook, kind: .food, opensAt: nil, now: now) == .needsDate)
    #expect(BookingOpening.classify(resolved: toBook, kind: .food,
      opensAt: Date(timeIntervalSince1970: 99), now: now) == .openNow)
    #expect(BookingOpening.classify(resolved: toBook, kind: .food,
      opensAt: now, now: now) == .openNow)
    #expect(BookingOpening.classify(resolved: toBook, kind: .food,
      opensAt: Date(timeIntervalSince1970: 101), now: now) == .opensLater(Date(timeIntervalSince1970: 101)))
    #expect(BookingOpening.classify(resolved: toBook, kind: .sight, opensAt: nil, now: now) == .notTracked)
    #expect(BookingOpening.classify(resolved: toBook, kind: .drink, opensAt: nil, now: now) == .notTracked)
  }

  @Test func ignoresRowsThatDoNotResolveToToBook() {
    for status: BookingStatus? in [.booked, .notNeeded, nil] {
      let resolved = ResolvedBooking(status: status, source: .explicit)
      #expect(BookingOpening.classify(
        resolved: resolved, kind: .food, opensAt: nil, now: .now) == nil)
    }
  }
}
