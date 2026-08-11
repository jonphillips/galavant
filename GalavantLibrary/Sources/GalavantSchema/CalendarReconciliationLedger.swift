import CryptoKit
import Foundation
import SQLiteData

/// The CloudKit-shared, reviewable result of one Calendar-authoritative change.
///
/// It has exactly one real foreign key — `tripID` — so it rides the existing trip
/// share and cascade-deletes with that trip (ADR-0007). `stopID` is deliberately
/// loose: a ledger record explains a stop even after that stop has been removed.
/// EventKit's local identifiers and this device's observation time never enter
/// this table. Instead, `id` is deterministically derived from a hash of the
/// Calendar source revision plus the semantic outcome. Two devices observing the
/// same change therefore write the same CloudKit record, rather than two records
/// that merely look alike (ADR-0034 §10).
@Table
public struct CalendarReconciliationLedgerEntry: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  /// Hash-only identity for the Calendar source snapshot. The raw server ID never
  /// leaves the EventKit boundary.
  public var sourceFingerprint: String
  public var kind: CalendarReconciliationHistoryEntry.Kind
  /// Loose UUID by the single-FK sharing rule. This record remains useful history
  /// if a planner later removes the stop.
  public var stopID: TripIdea.ID
  public var eventTitle: String
  public var previousIsAllDay: Bool?
  public var previousStartDate: Date?
  public var previousEndDate: Date?
  public var currentIsAllDay: Bool
  public var currentStartDate: Date
  public var currentEndDate: Date?

  public init(
    id: UUID,
    tripID: Trip.ID,
    sourceFingerprint: String,
    kind: CalendarReconciliationHistoryEntry.Kind,
    stopID: TripIdea.ID,
    eventTitle: String,
    previous: CalendarCommitment?,
    current: CalendarCommitment
  ) {
    self.id = id
    self.tripID = tripID
    self.sourceFingerprint = sourceFingerprint
    self.kind = kind
    self.stopID = stopID
    self.eventTitle = eventTitle
    (previousIsAllDay, previousStartDate, previousEndDate) = Self.columns(for: previous)
    let currentColumns = Self.columns(for: current)
    self.currentIsAllDay = currentColumns.isAllDay ?? false
    self.currentStartDate = currentColumns.startDate ?? .distantPast
    self.currentEndDate = currentColumns.endDate
  }

  /// Promotes a new Slice 2 history entry. Pre-Slice-3 local history deliberately
  /// has no cross-device source fingerprint, so it remains local instead of being
  /// guessed into shared state.
  public init?(
    tripID: Trip.ID,
    historyEntry: CalendarReconciliationHistoryEntry
  ) {
    guard let sourceFingerprint = historyEntry.sourceFingerprint else { return nil }
    let fingerprint = CalendarReconciliationFingerprint.outcome(
      tripID: tripID,
      sourceFingerprint: sourceFingerprint,
      kind: historyEntry.kind,
      stopID: historyEntry.stopID,
      previous: historyEntry.previous,
      current: historyEntry.current)
    self.init(
      id: CalendarReconciliationFingerprint.uuid(from: fingerprint),
      tripID: tripID,
      sourceFingerprint: sourceFingerprint,
      kind: historyEntry.kind,
      stopID: historyEntry.stopID,
      eventTitle: historyEntry.eventTitle,
      previous: historyEntry.previous,
      current: historyEntry.current)
  }

  public var previous: CalendarCommitment? {
    Self.commitment(isAllDay: previousIsAllDay, startDate: previousStartDate, endDate: previousEndDate)
  }

  public var current: CalendarCommitment? {
    Self.commitment(
      isAllDay: currentIsAllDay,
      startDate: currentStartDate,
      endDate: currentEndDate)
  }

  /// Idempotently write a generated ledger outcome in the same transaction as
  /// its itinerary update. A deterministic UUID is the cross-device dedup key;
  /// the lookup also makes repeated refreshes a no-op locally.
  public static func record(_ entry: CalendarReconciliationLedgerEntry, in db: Database) throws {
    guard try CalendarReconciliationLedgerEntry.find(entry.id).fetchOne(db) == nil else { return }
    try CalendarReconciliationLedgerEntry.insert {
      CalendarReconciliationLedgerEntry.Draft(entry)
    }
    .execute(db)
  }

  private static func columns(
    for commitment: CalendarCommitment?
  ) -> (isAllDay: Bool?, startDate: Date?, endDate: Date?) {
    switch commitment {
    case .none:
      (nil, nil, nil)
    case let .allDay(date):
      (true, date, nil)
    case let .timed(start, end):
      (false, start, end)
    }
  }

  private static func commitment(
    isAllDay: Bool?, startDate: Date?, endDate: Date?
  ) -> CalendarCommitment? {
    guard let isAllDay, let startDate else { return nil }
    if isAllDay { return .allDay(date: startDate) }
    guard let endDate else { return nil }
    return .timed(start: startDate, end: endDate)
  }
}

/// Stable, hash-only identity for a Calendar source snapshot and the shared
/// semantic outcome produced from it. This intentionally has no EventKit import,
/// so its inputs and guarantees are unit-testable in the package.
enum CalendarReconciliationFingerprint {
  static func source(for event: CalendarObservedEvent) -> String {
    let sourceIdentity = nonEmpty(event.externalIdentifier)
      ?? [
        normalized(event.calendarTitle), normalized(event.title), normalized(event.location ?? ""),
        event.latitude.map(stable) ?? "", event.longitude.map(stable) ?? "",
      ].joined(separator: "|")
    let revision = event.lastModifiedDate.map(stable)
      ?? [stable(event.startDate), stable(event.endDate), event.isAllDay ? "allDay" : "timed"].joined(separator: "|")
    return digest("calendar-source-v1|\(sourceIdentity)|\(revision)")
  }

  static func outcome(
    tripID: Trip.ID,
    sourceFingerprint: String,
    kind: CalendarReconciliationHistoryEntry.Kind,
    stopID: TripIdea.ID,
    previous: CalendarCommitment?,
    current: CalendarCommitment
  ) -> String {
    digest(
      [
        "calendar-outcome-v1", tripID.uuidString, sourceFingerprint, kind.rawValue,
        stopID.uuidString, commitmentDescription(previous), commitmentDescription(current),
      ].joined(separator: "|"))
  }

  static func uuid(from fingerprint: String) -> UUID {
    let hex = String(fingerprint.prefix(32))
    let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    // `fingerprint` is SHA-256 hexadecimal, so this cannot fail; preserve a
    // deterministic fallback rather than force-unwrapping a persistence key.
    return UUID(uuidString: uuidString) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  }

  private static func commitmentDescription(_ commitment: CalendarCommitment?) -> String {
    switch commitment {
    case .none: "none"
    case let .allDay(date): "allDay:\(stable(date))"
    case let .timed(start, end): "timed:\(stable(start)):\(stable(end))"
    }
  }

  private static func normalized(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  private static func stable(_ value: Date) -> String {
    String(value.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
  }

  private static func stable(_ value: Double) -> String {
    String(value.bitPattern, radix: 16)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
