import GalavantSchema
import SwiftUI

/// One planner's interest level as a single legible indicator (BACKLOG "His/hers
/// rating rendering redesign"): a 4-segment filled bar for the positive levels
/// (Must Do 4 / Want to Do 3 / Could Do 1, hot→cool tint), a red minus for Do Not
/// Do, a "?" for Decide Later, and an empty bar for *pending* (nil — not yet
/// rated), so Decide Later reads distinct from unrated. Fixed width, so a his/hers
/// pair lines up.
struct InterestView: View {
  let interest: Interest?

  private let segments = 4
  private var barWidth: CGFloat { CGFloat(segments) * 5 + CGFloat(segments - 1) * 2 }

  var body: some View {
    switch interest {
    case .some(.doNotDo):
      glyph("minus")
        .foregroundStyle(.red)
    case .some(.decideLater):
      glyph("questionmark")
        .foregroundStyle(.secondary)
    case let .some(level):
      bar(fill: level.barFill ?? 0, tint: tint(for: level))
    case .none:
      bar(fill: 0, tint: .secondary)  // pending — empty outline
    }
  }

  private func bar(fill: Int, tint: Color) -> some View {
    HStack(spacing: 2) {
      ForEach(0..<segments, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1.5)
          .fill(index < fill ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
          .frame(width: 5, height: 10)
      }
    }
  }

  private func glyph(_ name: String) -> some View {
    Image(systemName: name)
      .font(.caption.weight(.bold))
      .frame(width: barWidth, height: 10)
  }

  /// Hot (Must Do) → cool (Could Do) so a glance reads intensity from colour as
  /// well as fill.
  private func tint(for level: Interest) -> Color {
    switch level {
    case .mustDo: .red
    case .wantToDo: .orange
    case .couldDo: .yellow
    case .doNotDo, .decideLater: .secondary
    }
  }
}

/// The derived "both want it" badge — a warm-pink pill (the `.match` style from
/// docs/mockups/ideas-trip-awareness.html). A projection of the flames, not a
/// separate vote (ADR-0007).
struct MatchPill: View {
  var body: some View {
    Text("match")
      .font(.caption2)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(Capsule().fill(Color.pink.opacity(0.15)))
      .overlay(Capsule().strokeBorder(Color.pink.opacity(0.45), lineWidth: 0.5))
      .foregroundStyle(Color.pink)
  }
}

/// A menu for picking the current planner's interest in an idea.
struct InterestMenu<MenuLabel: View>: View {
  let current: Interest?
  let onSelect: (Interest?) -> Void
  @ViewBuilder var label: () -> MenuLabel

  var body: some View {
    Menu {
      ForEach([Interest.mustDo, .wantToDo, .couldDo, .doNotDo, .decideLater], id: \.self) { interest in
        Button {
          onSelect(interest)
        } label: {
          if current == interest {
            Label(interest.label, systemImage: Icon.checkmark.systemName)
          } else {
            Text(interest.label)
          }
        }
      }
      if current != nil {
        Divider()
        Button("Clear", role: .destructive) { onSelect(nil) }
      }
    } label: {
      label()
    }
  }
}
