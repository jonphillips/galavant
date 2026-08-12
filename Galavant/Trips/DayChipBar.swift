import GalavantSchema
import SwiftUI

/// The day lens for the trip canvas: a horizontal strip of pills — All, then
/// Day 1…N — overlaid on the top of the map. Selecting one sets
/// `model.canvasSelectedDay` (nil = All), which filters the map to that day and
/// frames its stops. Each day wears its `DayPalette` colour so the chip, its
/// pins, and its polyline read as one.
struct DayChipBar: View {
  let model: TripPlanningModel

  private var dayCount: Int { max(1, model.trip?.lengthInDays ?? 1) }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        chip(label: "All", color: nil, selected: model.canvasSelectedDay == nil) {
          model.canvasSelectedDay = nil
        }
        ForEach(1...dayCount, id: \.self) { day in
          chip(
            label: dayChipLabel(day, trip: model.trip),
            color: DayPalette.color(forDay: day),
            selected: model.canvasSelectedDay == day
          ) {
            model.canvasSelectedDay = day
          }
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
    .background(.bar)
  }

  private func chip(
    label: String,
    color: Color?,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let color {
          Circle().fill(color).frame(width: 10, height: 10)
        }
        Text(label).font(.subheadline.weight(selected ? .semibold : .regular))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        Capsule().fill(selected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary))
      )
      .overlay(
        Capsule().strokeBorder(
          selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
          lineWidth: 1.5
        )
      )
      .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
    .buttonStyle(.plain)
  }
}
