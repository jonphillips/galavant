import GalavantSchema
import SwiftUI
import UIKit

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
  /// The header image's thumbnail bytes, when the idea has one — shown in the
  /// leading slot in place of the kind glyph (M4f). Nil → the kind icon.
  var headerThumbnail: Data? = nil
  /// Every travel-party planner with their level (nil = pending), or empty when
  /// nobody has rated yet. Shown as the his/hers bars.
  let interests: [(planner: Planner, level: Interest?)]
  let isMatch: Bool
  let myInterest: Interest?
  let tripAccessory: TripAccessory
  let onTap: () -> Void
  let onSetInterest: (Interest?) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      leadingImage
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
              HStack(spacing: 4) {
                Text(entry.planner.displayName)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                InterestView(interest: entry.level)
              }
            }
            if isMatch { MatchPill() }
          }
        }
      }
      Spacer()
      trailingAccessories
    }
    .padding(.vertical, 2)
  }

  /// A small rounded header thumbnail when the idea has an image, else the kind
  /// glyph — same footprint either way so rows stay aligned.
  @ViewBuilder
  private var leadingImage: some View {
    if let headerThumbnail, let image = UIImage(data: headerThumbnail) {
      // Fit, not fill — wordmark/logo covers shouldn't be cropped to an unreadable
      // zoom; a faint backing keeps the cell tidy when the image is letterboxed.
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(width: 44, height: 44)
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    } else {
      Image(systemName: idea.kind?.systemImage ?? "mappin.and.ellipse")
        .foregroundStyle(.secondary)
        .frame(width: 44, height: 44)
    }
  }

  /// The trailing cluster. In the eternal pool: the derived trip badge, then the
  /// rating heart. Once scoped to a trip the heart becomes the left-most icon,
  /// followed by a vertical stack of the two pull toggles — a question mark
  /// (considering) over a checkmark (shortlisted).
  @ViewBuilder
  private var trailingAccessories: some View {
    switch tripAccessory {
    case let .badge(badge):
      if let badge { TripBadgeView(badge: badge) }
      interestHeart
    case let .pull(status, onConsidering, onShortlist):
      interestHeart
      VStack(spacing: 10) {
        pullToggle("questionmark", on: status == .considering, action: onConsidering)
        pullToggle("checkmark", on: status?.isOnShortlist == true, action: onShortlist)
      }
    }
  }

  private var interestHeart: some View {
    InterestMenu(current: myInterest, onSelect: onSetInterest) {
      Image(systemName: myInterest == nil ? "heart" : "heart.fill")
        .foregroundStyle(myInterest == nil ? Color.secondary : Color.red)
    }
  }

  /// One quick pull-state icon (considering / shortlist). These glyphs (a plain
  /// `questionmark` / `checkmark`) have no `.fill` cousin, so the lit state reads
  /// through tint + weight rather than a fill swap.
  private func pullToggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .imageScale(.large)
        .fontWeight(on ? .bold : .regular)
        .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
    .buttonStyle(.borderless)
  }
}
