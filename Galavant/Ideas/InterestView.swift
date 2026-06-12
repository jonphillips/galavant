import GalavantSchema
import SwiftUI

/// Compact heart glyphs for an interest value. Zero-heart values
/// (Do Not Do / Decide Later) show their label instead.
struct InterestView: View {
  let interest: Interest

  var body: some View {
    if interest.heartCount > 0 {
      HStack(spacing: 1) {
        ForEach(0..<interest.heartCount, id: \.self) { _ in
          Image(systemName: "heart.fill")
            .foregroundStyle(.red)
        }
      }
      .font(.caption2)
    } else {
      Text(interest.label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
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
            Label(interest.label, systemImage: "checkmark")
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
