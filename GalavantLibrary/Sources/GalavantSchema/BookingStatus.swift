import Foundation
import SQLiteData

/// The trip party's booking decision for one stop or stay (ADR-0047).
public enum BookingStatus: Int, QueryBindable, CaseIterable, Sendable {
  case notNeeded = 0
  case toBook = 1
  case booked = 2

  public var label: String {
    switch self {
    case .notNeeded: "Not needed"
    case .toBook: "To book"
    case .booked: "Booked"
    }
  }

  /// Resolve the strongest booking fact available for a trip row.
  public static func resolve(
    explicit: BookingStatus?,
    hasEvidence: Bool,
    inferred: BookingStatus?
  ) -> ResolvedBooking {
    if hasEvidence { return ResolvedBooking(status: .booked, source: .evidence) }
    if let explicit { return ResolvedBooking(status: explicit, source: .explicit) }
    return ResolvedBooking(status: inferred, source: .inferred)
  }

  /// Resolve directly from the synced booking evidence carried by a trip row.
  public static func resolve(
    explicit: BookingStatus?,
    pinnedDate: Date?,
    confirmationNumber: String?,
    inferred: BookingStatus?
  ) -> ResolvedBooking {
    resolve(
      explicit: explicit,
      hasEvidence: pinnedDate != nil || confirmationNumber.hasNonBlankText,
      inferred: inferred)
  }

  /// The stop-menu action is unavailable when evidence already says Booked.
  public static func quickAction(for booking: ResolvedBooking) -> BookingStatus? {
    guard booking.source != .evidence else { return nil }
    return booking.status == .booked ? .toBook : .booked
  }

  /// Kind-based guess used only when a stop has no booking evidence or decision.
  public static func inferred(for kind: IdeaKind?) -> BookingStatus? {
    switch kind {
    case .some(.tour), .some(.theater): .toBook
    case .some(.food), .some(.activity), .some(.museum), .some(.nightlife): nil
    case .some(.sight), .some(.drink), .some(.stay), .some(.beach), .some(.park),
      .some(.outdoorTrail), .some(.shop), .some(.market), .some(.transit), .none:
      .notNeeded
    }
  }
}

public struct ResolvedBooking: Equatable, Sendable {
  public enum Source: Equatable, Sendable {
    case evidence
    case explicit
    case inferred
  }

  public let status: BookingStatus?
  public let source: Source

  public init(status: BookingStatus?, source: Source) {
    self.status = status
    self.source = source
  }
}

extension TripIdea {
  /// Synced booking evidence deliberately excludes device-local Calendar state.
  public func resolvedBooking(idea: Idea?) -> ResolvedBooking {
    BookingStatus.resolve(
      explicit: bookingStatus,
      pinnedDate: pinnedDate,
      confirmationNumber: confirmationNumber,
      inferred: BookingStatus.inferred(for: idea?.kind))
  }
}

extension TripStay {
  public var resolvedBooking: ResolvedBooking {
    BookingStatus.resolve(
      explicit: bookingStatus,
      pinnedDate: nil,
      confirmationNumber: confirmationNumber,
      inferred: .toBook)
  }
}

private extension Optional where Wrapped == String {
  var hasNonBlankText: Bool {
    guard let self else { return false }
    return !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// Booking data that can be captured or edited independently of a stop's pin.
public struct BookingDetails: Equatable, Sendable {
  public var confirmationNumber: String?
  public var bookingURL: String?
  public var partySize: Int?

  public init(confirmationNumber: String?, bookingURL: String?, partySize: Int?) {
    self.confirmationNumber = confirmationNumber
    self.bookingURL = bookingURL
    self.partySize = partySize
  }
}
