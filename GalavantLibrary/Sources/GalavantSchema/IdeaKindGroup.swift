/// The quick-filter groups shown on the Ideas screen. Fine-grained kind filters
/// remain available in the filter menu.
public enum IdeaKindGroup: String, CaseIterable, Equatable, Sendable {
  case food
  case stay
  case other

  public init(kind: IdeaKind?) {
    switch kind {
    case .food, .drink:
      self = .food
    case .stay:
      self = .stay
    case .sight, .tour, .activity, .beach, .park, .outdoorTrail, .museum, .theater,
      .nightlife, .shop, .market, .transit, nil:
      self = .other
    }
  }

  public var label: String {
    switch self {
    case .food: "Food"
    case .stay: "Stay"
    case .other: "Other"
    }
  }

  public var systemImage: String {
    switch self {
    case .food: IdeaKind.food.systemImage
    case .stay: IdeaKind.stay.systemImage
    case .other: "mappin.and.ellipse"
    }
  }
}
