import GalavantSchema
import SwiftUI

/// A planning-screen row: the idea's kind icon, its name and region, and a
/// caller-supplied trailing control. Shared by the Ideas list, the Itinerary,
/// and the Add-Ideas sheet.
struct PlanningRow<Trailing: View>: View {
  let idea: Idea
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: idea.kind?.systemImage ?? "mappin.and.ellipse")
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        Text(idea.name)
        if let regionName = idea.regionName, !regionName.isEmpty {
          Text(regionName).font(.subheadline).foregroundStyle(.secondary)
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
