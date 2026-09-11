import GalavantSchema
import SwiftUI

/// The day lens for the trip canvas: a horizontal strip of pills — All, then
/// Day 1…N — overlaid on the top of the map. Selecting one sets
/// `model.canvasSelectedDay` (nil = All), which filters the map to that day and
/// frames its stops. Selecting a day also clears the lodging lens. Each day wears
/// its `DayPalette` colour so the chip, its pins, and its polyline read as one.
///
/// While the trip is underway the live day reads as **Today** — a named chip in a
/// strip of dates, ringed even when it isn't the selected one, so "where I am" and
/// "what I'm looking at" stay legible as two different things.
struct DayChipBar: View {
  let model: TripPlanningModel

  private var dayCount: Int { max(1, model.trip?.lengthInDays ?? 1) }

  var body: some View {
    let liveDay = model.liveDay
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        chip(
          label: "All",
          color: nil,
          selected: model.canvasSelectedDay == nil && model.canvasSelectedStayID == nil
        ) {
          model.selectCanvasDay(nil)
        }
        ForEach(1...dayCount, id: \.self) { day in
          let dateLabel = dayChipLabel(day, trip: model.trip)
          let isLive = day == liveDay
          chip(
            label: isLive ? "Today" : dateLabel,
            color: DayPalette.color(forDay: day),
            selected: model.canvasSelectedDay == day,
            isLive: isLive
          ) {
            model.selectCanvasDay(day)
          }
          .accessibilityLabel(isLive ? "Today, \(dateLabel)" : dateLabel)
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
    isLive: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let color {
          Circle().fill(color).frame(width: 10, height: 10)
        }
        Text(label).font(.subheadline.weight(selected || isLive ? .semibold : .regular))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        Capsule().fill(selected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary))
      )
      // Selected is a full tint ring; the unselected live day keeps a lighter one
      // so today is findable without competing with the lens you've chosen.
      .overlay(
        Capsule().strokeBorder(
          selected
            ? AnyShapeStyle(.tint)
            : isLive ? AnyShapeStyle(.tint.opacity(0.45)) : AnyShapeStyle(.clear),
          lineWidth: selected ? 1.5 : 1
        )
      )
      .foregroundStyle(selected || isLive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
    .buttonStyle(.plain)
  }
}
