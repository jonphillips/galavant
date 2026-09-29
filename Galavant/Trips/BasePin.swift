import GalavantSchema
import SwiftUI

/// A neutral lodging marker, distinct from the numbered route pins. Shared by
/// the trip canvas and Today's day map.
struct BasePin: View {
  let selected: Bool

  private static let unselectedDiameter: CGFloat = 28
  // The selected SequencePin is 26pt × 1.35 ≈ 35pt; make the base visibly larger
  // when the two annotations overlap.
  private static let selectedDiameter: CGFloat = 44

  var body: some View {
    Image(systemName: Icon.stay.systemName)
      .font((selected ? Font.body : .caption).bold())
      .foregroundStyle(.white)
      .frame(
        width: selected ? Self.selectedDiameter : Self.unselectedDiameter,
        height: selected ? Self.selectedDiameter : Self.unselectedDiameter
      )
      .background(Circle().fill(selected ? .blue : .gray))
      .overlay(Circle().strokeBorder(.white, lineWidth: 2))
      .shadow(radius: selected ? 6 : 1)
  }
}
