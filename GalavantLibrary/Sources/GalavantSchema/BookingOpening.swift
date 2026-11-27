import Foundation

public enum BookingOpening: Equatable, Sendable {
  case openNow
  case opensLater(Date)
  case needsDate
  case notTracked

  public static func classify(
    resolved: ResolvedBooking,
    kind: IdeaKind?,
    opensAt: Date?,
    now: Date
  ) -> BookingOpening? {
    guard resolved.status == .toBook else { return nil }
    if let opensAt {
      return opensAt <= now ? .openNow : .opensLater(opensAt)
    }
    return kind == .food ? .needsDate : .notTracked
  }
}
