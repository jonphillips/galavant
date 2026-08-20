import GalavantSchema
import SwiftUI

/// The lodging lens for the trip canvas: compact stay capsules above the day
/// chips. Stays are independent chips rather than a span aligned to the day grid.
struct LodgingCapsuleBar: View {
  let model: TripPlanningModel

  var body: some View {
    HStack(spacing: 8) {
      ForEach(model.plan.stays) { stay in
        capsule(for: stay)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }

  private func capsule(for stay: ResolvedStay) -> some View {
    let selected = model.canvasSelectedStayID == stay.id
    return Button {
      model.toggleCanvasStay(stay.id)
    } label: {
      HStack(spacing: 6) {
        Icon.stay.image
        Text(stay.content.title)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      .font(.subheadline.weight(selected ? .semibold : .regular))
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
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
    .accessibilityLabel(stay.content.title)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}
