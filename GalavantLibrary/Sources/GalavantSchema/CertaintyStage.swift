import SQLiteData

/// How committed a trip is — the storage discriminator behind the `Certainty`
/// pipeline (`someday → targeted → dated`, docs/trip-time-model.md). Raw values
/// order the stages from vaguest to most committed, so they sort naturally;
/// never renumber a shipped case.
public enum CertaintyStage: Int, QueryBindable, CaseIterable, Sendable {
  case someday = 0
  case targeted = 1
  case dated = 2

  public var label: String {
    switch self {
    case .someday: "Someday"
    case .targeted: "Targeted"
    case .dated: "Dated"
    }
  }
}
