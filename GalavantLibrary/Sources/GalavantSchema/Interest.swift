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

  /// A genuine "want it on the trip" signal — the threshold the match projection
  /// uses (trip-time-model.md §3's loud Must Do / Want to Do vs. quiet Could Do).
  public var isHigh: Bool {
    switch self {
    case .mustDo, .wantToDo: true
    case .couldDo, .doNotDo, .decideLater: false
    }
  }

  /// Fill level (of 4) for the rating bar, or nil for the levels that render as
  /// their own glyph instead of a bar (`doNotDo` = a minus, `decideLater` = a
  /// "?"). The positives spread 4/3/1 so they read apart at a glance.
  public var barFill: Int? {
    switch self {
    case .mustDo: 4
    case .wantToDo: 3
    case .couldDo: 1
    case .doNotDo, .decideLater: nil
    }
  }
}

/// Where an idea stands once the travel party's per-planner interests are taken
/// together — the "worklist" projection over the flames (a derivation, not a new
/// vote, so ADR-0007 stays intact). `match` floats up, `passed` sinks.
public enum MatchStanding: Sendable {
  case match    // ≥2 planners want it (≥ Want to Do)
  case neutral
  case passed   // ≥2 planners said Do Not Do, none high — mutually rejected

  /// Sort rank: matches first, passed last.
  public var sortKey: Int {
    switch self {
    case .match: 0
    case .neutral: 1
    case .passed: 2
    }
  }
}

extension Interest {
  /// Project a set of per-planner levels (nil = a planner who hasn't rated) onto
  /// the shared standing. Pure, so it's the densely-tested core.
  public static func standing(_ levels: [Interest?]) -> MatchStanding {
    let rated = levels.compactMap { $0 }
    if rated.filter(\.isHigh).count >= 2 { return .match }
    if rated.filter({ $0 == .doNotDo }).count >= 2, !rated.contains(where: \.isHigh) {
      return .passed
    }
    return .neutral
  }

  /// Both (≥2) planners rated this highly — the badge/filter signal.
  public static func isMatch(_ levels: [Interest?]) -> Bool {
    standing(levels) == .match
  }
}
