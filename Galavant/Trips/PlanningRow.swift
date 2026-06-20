import GalavantSchema
import SwiftUI

/// A planning-screen row: a kind icon, a name/subtitle, and a caller-supplied
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
  @ViewBuilder var trailing: Trailing

  init(content: StopContent, subtitle: Subtitle = .region, @ViewBuilder trailing: () -> Trailing) {
    self.content = content
    self.subtitle = subtitle
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
      Image(systemName: content.idea?.kind?.systemImage ?? "mappin.and.ellipse")
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .padding(.top, 2)
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
}

/// "Day 3" for an undated trip, "Day 3 · Wed, Jun 17" once it's dated — shared by
/// the day headers, the Move-to-Day menu, and the Add-Stop sheet.
func dayLabel(_ number: Int, trip: Trip?) -> String {
  guard let date = trip?.date(forDay: number) else { return "Day \(number)" }
  return "Day \(number) · "
    + date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
}
