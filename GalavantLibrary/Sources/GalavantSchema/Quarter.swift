import SQLiteData

/// A coarse season target for a `targeted` trip — year + quarter, the
/// "Denmark next spring" precision before exact dates bind (V1's
/// YearSeasonPicker). Optional even within `targeted`: a year alone is allowed.
public enum Quarter: Int, QueryBindable, CaseIterable, Sendable {
  case q1 = 1
  case q2 = 2
  case q3 = 3
  case q4 = 4

  public var label: String {
    switch self {
    case .q1: "Q1"
    case .q2: "Q2"
    case .q3: "Q3"
    case .q4: "Q4"
    }
  }

  /// The months the quarter spans, for a friendlier label than "Q2".
  public var monthRange: String {
    switch self {
    case .q1: "Jan–Mar"
    case .q2: "Apr–Jun"
    case .q3: "Jul–Sep"
    case .q4: "Oct–Dec"
    }
  }
}
