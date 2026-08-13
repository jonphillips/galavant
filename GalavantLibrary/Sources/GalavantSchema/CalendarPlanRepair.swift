import Foundation
import SQLiteData

/// A travel-party-shared decision created when Calendar changes a commitment but
/// cannot decide how the surrounding itinerary should adapt. Calendar remains
/// authoritative for the commitment; this record preserves the human repair work
/// without pretending Calendar chose that repair (ADR-0034 §§5, 7).
@Table
public struct CalendarPlanRepair: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  /// A deterministic hash of the Calendar revision that caused this question.
  /// Raw EventKit identity stays device-local.
  public var sourceFingerprint: String
  public var stopID: TripIdea.ID
  public var title: String
  public var kind: CalendarPlanRepairKind
  public var commitmentSnapshot: String
  public var isResolved: Bool
  public var resolvedAt: Date?

  public init?(
    tripID: Trip.ID,
    sourceFingerprint: String,
    stopID: TripIdea.ID,
    title: String,
    kind: CalendarPlanRepairKind,
    commitment: CalendarCommitment
  ) {
    guard let commitmentSnapshot = Self.encode(commitment) else { return nil }
    self.id = CalendarReconciliationFingerprint.planRepairID(
      tripID: tripID, sourceFingerprint: sourceFingerprint, stopID: stopID, kind: kind)
    self.tripID = tripID
    self.sourceFingerprint = sourceFingerprint
    self.stopID = stopID
    self.title = title
    self.kind = kind
    self.commitmentSnapshot = commitmentSnapshot
    isResolved = false
    resolvedAt = nil
  }

  public var commitment: CalendarCommitment? { Self.decode(commitmentSnapshot) }

  /// Recording is deliberately idempotent: the same Calendar revision seen by
  /// both phones must preserve one shared outstanding decision and never reopen
  /// one a planner already addressed.
  public static func record(_ repair: Self, in db: Database) throws {
    guard try Self.find(repair.id).fetchOne(db) == nil else { return }
    try Self.insert { Self.Draft(repair) }.execute(db)
  }

  public static func resolve(id: Self.ID, at date: Date, in db: Database) throws {
    try Self.find(id)
      .update {
        $0.isResolved = #bind(true)
        $0.resolvedAt = #bind(date)
      }
      .execute(db)
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

public enum CalendarPlanRepairKind: String, Codable, Equatable, Sendable, QueryBindable {
  /// The commitment now lands on another itinerary day. Its time was applied;
  /// only the surrounding route/order needs a planner's judgment.
  case movedDay
  /// The linked commitment still exists, but now sits beyond this trip's dates.
  case movedOutsideTrip

  public var detail: String {
    switch self {
    case .movedDay: "Calendar moved this commitment to another trip day. Check the surrounding plan."
    case .movedOutsideTrip: "Calendar moved this commitment outside the trip. Decide whether to extend or replan."
    }
  }
}

extension CalendarReconciliation {
  /// Derive shared repair questions from the already-validated automatic update
  /// plan. An ordinary clock-time edit stays an authoritative cache refresh; only
  /// a day move or an out-of-trip move needs itinerary repair.
  public static func planRepairs(
    applications: [CalendarReconciliationApplication],
    previousDayNumbers: [TripIdea.ID: DayNumber],
    history: [CalendarReconciliationHistoryEntry],
    tripID: Trip.ID
  ) -> [CalendarPlanRepair] {
    let dayMoveRepairs = applications.compactMap { application -> CalendarPlanRepair? in
      guard application.kind == .updated,
        let previousDay = previousDayNumbers[application.stopID], previousDay != application.dayNumber,
        let sourceFingerprint = application.sourceFingerprint
      else { return nil }
      return CalendarPlanRepair(
        tripID: tripID, sourceFingerprint: sourceFingerprint,
        stopID: application.stopID, title: application.eventTitle,
        kind: .movedDay, commitment: application.commitment)
    }
    let outsideRepairs = history.compactMap { entry -> CalendarPlanRepair? in
      guard entry.kind == .movedOutsideTrip, let sourceFingerprint = entry.sourceFingerprint else { return nil }
      return CalendarPlanRepair(
        tripID: tripID, sourceFingerprint: sourceFingerprint,
        stopID: entry.stopID, title: entry.eventTitle,
        kind: .movedOutsideTrip, commitment: entry.current)
    }
    return dayMoveRepairs + outsideRepairs
  }
}
