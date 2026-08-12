import GalavantSchema
import SwiftUI

/// The leading glyph a `PlanningRow` shows. `.kind` (the default) is the idea's
/// category icon — what every pool/shortlist/Add-Ideas row wears. `.sequence`
/// draws a day-coloured `SequencePin`, used only by the day-itinerary timeline so
/// a located stop's row number matches its map pin (the unlocated rows there stay
/// on `.kind`, since they have no pin).
enum PlanningRowMarker {
  case kind
  case sequence(Int, Color)
}

/// A planning-screen row: a leading marker, a name/subtitle, and a caller-supplied
/// trailing control. Shared by the Ideas list, the Itinerary, and the
/// Add-Ideas sheet. Accepts a `StopContent` directly (for any itinerary stop,
/// idea-backed or freeform) or an `Idea` convenience init (for the pool sheet).
struct PlanningRow<Trailing: View>: View {
  /// What the subtitle line carries. Inside a (single-destination) trip the city
  /// is redundant, so the Itinerary and Trip Ideas tab show the **category**
  /// instead (signal, not the city context already supplies); the Add-Ideas
  /// sheet browses the wider regional pool, where the city still disambiguates.
  enum Subtitle { case region, category }

  let content: StopContent
  var subtitle: Subtitle = .region
  /// The leading glyph — the kind icon by default; the day itinerary passes a
  /// `.sequence` to mirror the map pins.
  var marker: PlanningRowMarker = .kind
  @ViewBuilder var trailing: Trailing

  init(
    content: StopContent,
    subtitle: Subtitle = .region,
    marker: PlanningRowMarker = .kind,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.content = content
    self.subtitle = subtitle
    self.marker = marker
    self.trailing = trailing()
  }

  init(idea: Idea, subtitle: Subtitle = .region, @ViewBuilder trailing: () -> Trailing) {
    self.content = .idea(idea)
    self.subtitle = subtitle
    self.trailing = trailing()
  }

  private var subtitleText: String? {
    switch subtitle {
    case .region: content.idea?.regionName.flatMap { $0.isEmpty ? nil : $0 }
    case .category: content.idea?.kind?.label
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      leadingMarker
      VStack(alignment: .leading, spacing: 2) {
        Text(content.title)
        if let subtitleText {
          Text(subtitleText).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Spacer()
      trailing
    }
    .padding(.vertical, 2)
  }

  /// The kind icon (default), or a day-coloured `SequencePin` matching the stop's
  /// map pin. Both occupy a 26-wide slot so the title column stays aligned whether
  /// a row carries a number or an icon.
  @ViewBuilder private var leadingMarker: some View {
    switch marker {
    case .kind:
      Image(systemName: content.idea?.kind?.systemImage ?? "mappin.and.ellipse")
        .foregroundStyle(.secondary)
        .frame(width: 26)
        .padding(.top, 2)
    case let .sequence(number, color):
      SequencePin(number: number, color: color)
        .frame(width: 26)
    }
  }
}

/// "Day 3" for an undated trip, "Day 3 · Wed, Jun 17" once it's dated — shared by
/// the day headers, the Move-to-Day menu, and the Add-Stop sheet.
func dayLabel(_ number: Int, trip: Trip?) -> String {
  guard let date = trip?.date(forDay: number) else { return "Day \(number)" }
  return "Day \(number) · "
    + date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
}

/// Compact day label for the chip strip: "M 8/24" on a dated trip, "Day N"
/// when undated. The ambiguous Tuesday/Thursday and Saturday/Sunday initials
/// expand to two letters while the other weekdays stay at one.
func dayChipLabel(_ number: Int, trip: Trip?) -> String {
  guard let date = trip?.date(forDay: number) else { return "Day \(number)" }
  let weekday = switch Calendar.current.component(.weekday, from: date) {
  case 1: "Su"
  case 2: "M"
  case 3: "Tu"
  case 4: "W"
  case 5: "Th"
  case 6: "F"
  case 7: "Sa"
  default: ""
  }
  let monthDay = date.formatted(.dateTime.month(.defaultDigits).day())
  return "\(weekday) \(monthDay)"
}
