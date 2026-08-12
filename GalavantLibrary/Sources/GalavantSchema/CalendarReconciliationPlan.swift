public struct CalendarReconciliationApplication: Equatable, Sendable {
  public var stopID: TripIdea.ID
  public var commitment: CalendarCommitment
  public var dayNumber: DayNumber
  public var kind: CalendarReconciliationHistoryEntry.Kind

  public init(
    stopID: TripIdea.ID,
    commitment: CalendarCommitment,
    dayNumber: DayNumber,
    kind: CalendarReconciliationHistoryEntry.Kind
  ) {
    self.stopID = stopID
    self.commitment = commitment
    self.dayNumber = dayNumber
    self.kind = kind
  }
}

public struct CalendarReconciliationAutomaticPlan: Equatable, Sendable {
  public var applications: [CalendarReconciliationApplication]
  public var localState: CalendarReconciliationLocalState

  public init(
    applications: [CalendarReconciliationApplication],
    localState: CalendarReconciliationLocalState
  ) {
    self.applications = applications
    self.localState = localState
  }
}
