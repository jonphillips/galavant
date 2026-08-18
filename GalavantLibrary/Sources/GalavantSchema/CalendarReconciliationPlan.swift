public struct CalendarReconciliationApplication: Equatable, Sendable {
  public var stopID: TripIdea.ID
  public var commitment: CalendarCommitment
  public var dayNumber: DayNumber
  public var kind: CalendarReconciliationHistoryEntry.Kind
  public var sourceFingerprint: String?
  public var eventTitle: String
  public var calendarNotes: String?

  public init(
    stopID: TripIdea.ID,
    commitment: CalendarCommitment,
    dayNumber: DayNumber,
    kind: CalendarReconciliationHistoryEntry.Kind,
    sourceFingerprint: String? = nil,
    eventTitle: String = "",
    calendarNotes: String? = nil
  ) {
    self.stopID = stopID
    self.commitment = commitment
    self.dayNumber = dayNumber
    self.kind = kind
    self.sourceFingerprint = sourceFingerprint
    self.eventTitle = eventTitle
    self.calendarNotes = calendarNotes
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

public struct CalendarConstraintAutomaticPlan: Equatable, Sendable {
  public var upserts: [CalendarTripConstraint]
  public var deletions: [CalendarTripConstraint.ID]
  public var localState: CalendarReconciliationLocalState

  public init(
    upserts: [CalendarTripConstraint],
    deletions: [CalendarTripConstraint.ID],
    localState: CalendarReconciliationLocalState
  ) {
    self.upserts = upserts
    self.deletions = deletions
    self.localState = localState
  }
}

public struct CalendarReconciliationUnlinkPlan: Equatable, Sendable {
  public var stopID: TripIdea.ID
  public var localState: CalendarReconciliationLocalState

  public init(stopID: TripIdea.ID, localState: CalendarReconciliationLocalState) {
    self.stopID = stopID
    self.localState = localState
  }
}
