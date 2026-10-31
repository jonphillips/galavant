import GalavantSchema
import SwiftUI

/// One horizontal lens strip: All, then day groups labeled by the stay slept in
/// that night. The live day reads as Today and keeps its ring even when it isn't
/// selected, so the user's position stays distinct from the chosen lens. Day
/// color remains reserved for map pins and routes.
struct DayChipBar: View {
  let model: TripPlanningModel
  let bookingByRow: [TripBookingRow: ResolvedBooking]

  private var groups: [StayDayGroup] { model.plan.stayDayGroups() }

  var body: some View {
    let liveDay = model.liveDay
    let groups = groups
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        chip(
          label: "All",
          selected: model.canvasSelectedDay == nil && model.canvasSelectedStayID == nil
        ) {
          model.selectCanvasDay(nil)
        }

        if !groups.isEmpty {
          Divider().frame(height: 24)
        }

        ForEach(groups) { group in
          HStack(spacing: 8) {
            if let stay = group.stay {
              stayChip(stay)
            }
            ForEach(group.days, id: \.self) { day in
              let dateLabel = dayChipLabel(day, trip: model.trip)
              let fullLabel = dayAccessibilityLabel(day, trip: model.trip)
              let isLive = day == liveDay
              chip(
                label: isLive ? "Today" : dateLabel,
                selected: model.canvasSelectedDay == day,
                isLive: isLive
              ) {
                model.selectCanvasDay(day)
              }
              .accessibilityLabel(isLive ? "Today, \(fullLabel)" : fullLabel)
            }
          }
          if group.id != groups.last?.id {
            Divider().frame(height: 24)
          }
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
    .background(.bar)
  }

  private func stayChip(_ stay: ResolvedStay) -> some View {
    let selected = model.canvasSelectedStayID == stay.id
    let booking = bookingByRow[.stay(stay.id)]
    return Button {
      model.toggleCanvasStay(stay.id)
    } label: {
      HStack(spacing: 6) {
        Icon.stay.image
        Text(stay.content.title)
          .lineLimit(1)
          .frame(maxWidth: 140, alignment: .leading)
        if booking?.status == .toBook {
          BookingStatusGlyph(booking: booking)
        }
      }
      .font(.subheadline.weight(selected ? .semibold : .regular))
      .padding(.horizontal, 10)
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
    .accessibilityLabel("\(stay.content.title), stay")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  private func chip(
    label: String,
    selected: Bool,
    isLive: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(label).font(.subheadline.weight(selected || isLive ? .semibold : .regular))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
          Capsule().fill(selected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary))
        )
        // Selected is a full tint ring; the unselected live day keeps a lighter
        // one so today is findable without competing with the chosen lens.
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
