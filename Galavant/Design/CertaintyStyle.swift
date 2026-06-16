import GalavantSchema
import SwiftUI

/// The colour a trip's certainty stage wears in chrome — the dot on an
/// active-trip capsule and the tint of an idea's trip-association badge both
/// draw from this, so "how committed is this trip" reads as one hue wherever a
/// trip surfaces on the Ideas screen. Presentation only (like `DayPalette`), so
/// it lives app-side rather than on the schema enum.
extension CertaintyStage {
  var tint: Color {
    switch self {
    case .dated: .blue
    case .targeted: .orange
    case .someday: .secondary
    }
  }
}
