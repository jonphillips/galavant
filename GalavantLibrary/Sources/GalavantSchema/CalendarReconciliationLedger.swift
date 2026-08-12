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
/// Calendar source revision plus the shared resulting commitment. Two devices
/// observing the same change therefore write the same CloudKit record, regardless
/// of their distinct device-local EventKit binding histories (ADR-0034 §10).
@Table
public struct CalendarReconciliationLedgerEntry: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  /// Hash-only identity for the Calendar source snapshot. The raw server ID never
  /// leaves the EventKit boundary.
  public var sourceFingerprint: String
  /// Loose UUID by the single-FK sharing rule. This record remains useful history
  /// if a planner later removes the stop.
  public var stopID: TripIdea.ID
  public var eventTitle: String
  public var currentIsAllDay: Bool
  public var currentStartDate: Date
  public var currentEndDate: Date?
  /// Complete temporal + availability snapshot. The original columns remain as
  /// a backward-compatible projection for Slice 3 rows; this encoded value is the
  /// authoritative representation for floating, all-day, and zoned semantics.
  public var currentSnapshot: String?

  public init(
    id: UUID,
    tripID: Trip.ID,
    sourceFingerprint: String,
    stopID: TripIdea.ID,
    eventTitle: String,
    current: CalendarCommitment
  ) {
    self.id = id
    self.tripID = tripID
    self.sourceFingerprint = sourceFingerprint
    self.stopID = stopID
    self.eventTitle = eventTitle
    let currentColumns = Self.persistedColumns(for: current)
    self.currentIsAllDay = currentColumns.isAllDay
    self.currentStartDate = currentColumns.startDate
    self.currentEndDate = currentColumns.endDate
    self.currentSnapshot = Self.encode(current)
  }

  /// Promotes a new history entry. It only promotes server-identified events: a
  /// display-derived fallback cannot prove two devices saw one event. The local
  /// transition (`linked` versus `updated`, including its previous value) remains
  /// in device-local history; this shared row records the resulting *applied* fact.
  ///
  /// A `.movedOutsideTrip` entry never promotes: it applied nothing to the shared
  /// itinerary (the cache is deliberately preserved), so it is a device-local
  /// observation, not a shared outcome. Surfacing a moved commitment as a party-wide
  /// conflict is Slice 6 (plan-repair), not this ledger.
  public init?(
    tripID: Trip.ID,
    historyEntry: CalendarReconciliationHistoryEntry
  ) {
    guard historyEntry.kind != .movedOutsideTrip else { return nil }
    guard let sourceFingerprint = historyEntry.sourceFingerprint else { return nil }
    let fingerprint = CalendarReconciliationFingerprint.outcome(
      tripID: tripID,
      sourceFingerprint: sourceFingerprint,
      stopID: historyEntry.stopID,
      current: historyEntry.current)
    self.init(
      id: CalendarReconciliationFingerprint.uuid(from: fingerprint),
      tripID: tripID,
      sourceFingerprint: sourceFingerprint,
      stopID: historyEntry.stopID,
      eventTitle: historyEntry.eventTitle,
      current: historyEntry.current)
  }

  public var current: CalendarCommitment? {
    if let currentSnapshot, let decoded = Self.decode(currentSnapshot) { return decoded }
    return Self.commitment(
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

  private static func persistedColumns(
    for commitment: CalendarCommitment
  ) -> (isAllDay: Bool, startDate: Date, endDate: Date?) {
    let utc = TimeZone(secondsFromGMT: 0)!
    switch commitment.temporal {
    case let .absolute(start, end, _):
      return (false, start, end)
    case let .floating(start, end):
      return (false, start.instant(in: utc)!, end.instant(in: utc)!)
    case let .allDay(start, _):
      return (true, start.date(in: utc)!, nil)
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

  private static func encode(_ commitment: CalendarCommitment) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? String(decoding: encoder.encode(commitment), as: UTF8.self)
  }

  private static func decode(_ value: String) -> CalendarCommitment? {
    try? JSONDecoder().decode(CalendarCommitment.self, from: Data(value.utf8))
  }
}

/// Stable, hash-only identity for a Calendar source snapshot and the shared
/// semantic outcome produced from it. This intentionally has no EventKit import,
/// so its inputs and guarantees are unit-testable in the package.
enum CalendarReconciliationFingerprint {
  static func source(for event: CalendarObservedEvent) -> String? {
    guard let sourceIdentity = nonEmpty(event.externalIdentifier) else { return nil }
    if event.recurrence == nil,
      case let .absolute(start, end, _) = event.temporal
    {
      // Preserve Slice 3 identity for the already-shipped ordinary timed case.
      let revision = event.lastModifiedDate.map(stable)
        ?? [stable(start), stable(end), "timed"].joined(separator: "|")
      return digest("calendar-source-v1|\(sourceIdentity)|\(revision)")
    }
    let revision = event.lastModifiedDate.map(stable) ?? event.temporal.stableDescription
    let occurrence = event.recurrence?.originalOccurrence.stableDescription ?? "standalone"
    return digest("calendar-source-v2|\(sourceIdentity)|\(revision)|\(occurrence)")
  }

  static func outcome(
    tripID: Trip.ID,
    sourceFingerprint: String,
    stopID: TripIdea.ID,
    current: CalendarCommitment
  ) -> String {
    digest(
      [
        "calendar-outcome-v1", tripID.uuidString, sourceFingerprint,
        stopID.uuidString, commitmentDescription(current),
      ].joined(separator: "|"))
  }

  static func constraintSource(for event: CalendarObservedEvent) -> String? {
    guard let sourceIdentity = nonEmpty(event.externalIdentifier) else { return nil }
    let occurrence = event.recurrence?.originalOccurrence.stableDescription ?? "standalone"
    return digest("calendar-constraint-source-v1|\(sourceIdentity)|\(occurrence)")
  }

  static func constraintID(
    tripID: Trip.ID,
    sourceIdentityHash: String
  ) -> UUID {
    uuid(from: digest(
      "calendar-constraint-v1|\(tripID.uuidString)|\(sourceIdentityHash)"))
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
    case let .some(commitment):
      "\(commitment.temporal.stableDescription)|availability:\(commitment.availability.rawValue)"
    }
  }

  private static func stable(_ value: Date) -> String {
    String(value.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
