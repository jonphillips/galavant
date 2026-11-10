import GalavantSchema
import SwiftUI

struct RankMedal: View {
  let priority: Int?
  let priorityOutOf: Int?
  var listName: String? = nil

  private var tier: ChatRankMedal.Tier? {
    ChatRankMedal.tier(priority: priority, priorityOutOf: priorityOutOf)
  }

  private var tint: Color {
    switch tier {
    case .gold: .yellow
    case .silver: .gray
    case .bronze: .brown
    case nil: .clear
    }
  }

  private var numeralColor: Color {
    switch tier {
    case .gold, .silver: .black
    case .bronze: .white
    case nil: .clear
    }
  }

  var body: some View {
    if tier != nil, let priority,
      let label = ChatRankMedal.accessibilityLabel(priority: priority, priorityOutOf: priorityOutOf)
    {
      Text(priority.formatted())
        .font(.caption2.weight(.bold))
        .monospacedDigit()
        .foregroundStyle(numeralColor)
        .frame(width: 18, height: 18)
        .background(tint, in: Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.75) }
        .accessibilityLabel(listName.map { "\(label), \($0)" } ?? label)
        .accessibilityAddTraits(.isStaticText)
    }
  }
}
