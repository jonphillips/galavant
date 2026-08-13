import Foundation

/// An absolute Calendar commitment constrains the otherwise-relative start date:
/// if this stop is on Day 3 and Calendar says September 15, Day 1 is September
/// 13. It is evidence for the start-day solver, never an instruction to silently
/// rewrite the trip (ADR-0034 §8).
public struct TripStartAnchor: Equatable, Identifiable, Sendable {
  public let stopID: TripIdea.ID
  public var stopName: String
  public var dayNumber: DayNumber
  public var commitmentDate: CalendarCivilDate

  public var id: TripIdea.ID { stopID }

  public init(
    stopID: TripIdea.ID,
    stopName: String,
    dayNumber: DayNumber,
    commitmentDate: CalendarCivilDate
  ) {
    self.stopID = stopID
    self.stopName = stopName
    self.dayNumber = dayNumber
    self.commitmentDate = commitmentDate
  }

  public var proposedStart: CalendarCivilDate? {
    commitmentDate.adding(days: 1 - dayNumber)
  }
}

/// The complete, advisory outcome of comparing every absolute commitment anchor.
/// A single derived start is useful evidence; divergent starts remain an explicit
/// conflict for planners to resolve rather than moving the trip automatically.
public struct StartDayAnchorAssessment: Equatable, Sendable {
  public var anchors: [TripStartAnchor]
  public var proposedStart: CalendarCivilDate?
  public var conflictingAnchors: [TripStartAnchor]

  public init(
    anchors: [TripStartAnchor],
    proposedStart: CalendarCivilDate?,
    conflictingAnchors: [TripStartAnchor]
  ) {
    self.anchors = anchors
    self.proposedStart = proposedStart
    self.conflictingAnchors = conflictingAnchors
  }

  public var isConsistent: Bool { anchors.isEmpty || conflictingAnchors.isEmpty }
}

extension StartDaySolver {
  /// Compare Calendar-derived starts. This stays separate from weekday/opening-
  /// hours scoring: anchors constrain a real calendar date, whereas hours score
  /// the seven relative weekday choices.
  public static func assess(anchors: [TripStartAnchor]) -> StartDayAnchorAssessment {
    let valid = anchors.filter { $0.proposedStart != nil }
    guard let proposedStart = valid.first?.proposedStart else {
      return StartDayAnchorAssessment(anchors: valid, proposedStart: nil, conflictingAnchors: [])
    }
    let conflicting = valid.filter { $0.proposedStart != proposedStart }
    return StartDayAnchorAssessment(
      anchors: valid, proposedStart: proposedStart,
      conflictingAnchors: conflicting)
  }
}
