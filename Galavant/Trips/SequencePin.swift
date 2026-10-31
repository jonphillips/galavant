import SwiftUI

/// A numbered stop marker. Map pins use their day's color; itinerary badges use a
/// neutral fill with primary text. On the map it swells and lifts when selected.
struct SequencePin: View {
  enum Style: Equatable { case dayColor, neutral }

  let number: Int
  let color: Color
  var style: Style = .dayColor
  var selected: Bool = false

  var body: some View {
    Text("\(number)")
      .font(.caption.bold())
      .foregroundStyle(
        style == .neutral ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.white))
      .frame(width: 26, height: 26)
      .background(Circle().fill(style == .neutral ? Color(.secondarySystemFill) : color))
      .overlay {
        if style == .dayColor {
          Circle().strokeBorder(.white, lineWidth: 2)
        }
      }
      .scaleEffect(selected ? 1.35 : 1)
      .shadow(radius: selected ? 4 : 1)
      .animation(.spring(duration: 0.25), value: selected)
  }
}
