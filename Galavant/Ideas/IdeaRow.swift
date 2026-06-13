import GalavantSchema
import SwiftUI

struct IdeaRow: View {
  let idea: Idea
  let interests: [(planner: Planner, level: Interest)]
  let myInterest: Interest?
  let onTap: () -> Void
  let onSetInterest: (Interest?) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: idea.kind?.systemImage ?? "mappin.and.ellipse")
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 4) {
        Button(action: onTap) {
          VStack(alignment: .leading, spacing: 2) {
            Text(idea.name)
              .foregroundStyle(.primary)
            if let regionName = idea.regionName, !regionName.isEmpty {
              Text(regionName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
        }
        .buttonStyle(.plain)
        if !interests.isEmpty {
          HStack(spacing: 10) {
            ForEach(interests, id: \.planner.id) { entry in
              HStack(spacing: 3) {
                Text(entry.planner.displayName)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                InterestView(interest: entry.level)
              }
            }
          }
        }
      }
      Spacer()
      InterestMenu(current: myInterest, onSelect: onSetInterest) {
        Image(systemName: myInterest == nil ? "heart" : "heart.fill")
          .foregroundStyle(myInterest == nil ? Color.secondary : Color.red)
      }
    }
    .padding(.vertical, 2)
  }
}
