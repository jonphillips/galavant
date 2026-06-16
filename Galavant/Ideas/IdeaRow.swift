import GalavantSchema
import SwiftUI

struct IdeaRow: View {
  /// The cell's trailing trip-awareness affordance, before the rating heart.
  /// Two modes (BACKLOG "Ideas list trip-awareness"): the eternal pool shows a
  /// derived association badge; an active-trip capsule turns the row into a
  /// pull/shortlist surface for that trip.
  enum TripAccessory {
    case badge(IdeaTripBadge?)
    case pull(status: TripIdeaStatus?, onConsidering: () -> Void, onShortlist: () -> Void)
  }

  let idea: Idea
  let interests: [(planner: Planner, level: Interest)]
  let myInterest: Interest?
  let tripAccessory: TripAccessory
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
      tripAccessoryView
      InterestMenu(current: myInterest, onSelect: onSetInterest) {
        Image(systemName: myInterest == nil ? "heart" : "heart.fill")
          .foregroundStyle(myInterest == nil ? Color.secondary : Color.red)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var tripAccessoryView: some View {
    switch tripAccessory {
    case let .badge(badge):
      if let badge { TripBadgeView(badge: badge) }
    case let .pull(status, onConsidering, onShortlist):
      HStack(spacing: 16) {
        pullToggle(Icon.consider, on: status == .considering, action: onConsidering)
        pullToggle(Icon.shortlist, on: status?.isOnShortlist == true, action: onShortlist)
      }
    }
  }

  /// One quick pull-state icon (considering / shortlist), lit when in that state
  /// — mirrors the Add-Ideas sheet's `addToggle`.
  private func pullToggle(_ icon: Icon, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: on ? "\(icon.systemName).fill" : icon.systemName)
        .imageScale(.large)
        .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
    .buttonStyle(.borderless)
  }
}
