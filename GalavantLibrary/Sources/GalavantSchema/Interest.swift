import SQLiteData

/// A planner's pre-trip interest in an idea — how much they want it on a trip,
/// set before going (distinct from a post-visit quality verdict). Values match
/// V1's NoteRating so legacy data could be migrated; never renumber a shipped case.
public enum Interest: Int, QueryBindable, CaseIterable, Sendable {
  case doNotDo = 1
  case decideLater = 0
  case couldDo = 2
  case wantToDo = 3
  case mustDo = 4

  public var label: String {
    switch self {
    case .mustDo: "Must Do"
    case .wantToDo: "Want to Do"
    case .couldDo: "Could Do"
    case .doNotDo: "Do Not Do"
    case .decideLater: "Decide Later"
    }
  }

  /// Number of filled hearts (0–3); `doNotDo` and `decideLater` show none.
  public var heartCount: Int {
    switch self {
    case .mustDo: 3
    case .wantToDo: 2
    case .couldDo: 1
    case .doNotDo, .decideLater: 0
    }
  }
}
