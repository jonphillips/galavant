import SwiftUI

/// A numbered stop marker in its day's colour — a white number on a day-coloured
/// circle. Shared by the canvas map (`TripCanvasMapView`) and the itinerary
/// timeline (`PlanningRow`) so a located stop's row number reads as the same token
/// as its map pin. On the map it swells and lifts when it's the shared selection;
/// in a list it sits static (`selected: false`, the default).
struct SequencePin: View {
  let number: Int
  let color: Color
  var selected: Bool = false

  var body: some View {
    Text("\(number)")
      .font(.caption.bold())
      .foregroundStyle(.white)
      .frame(width: 26, height: 26)
      .background(Circle().fill(color))
      .overlay(Circle().strokeBorder(.white, lineWidth: 2))
      .scaleEffect(selected ? 1.35 : 1)
      .shadow(radius: selected ? 4 : 1)
      .animation(.spring(duration: 0.25), value: selected)
  }
}
