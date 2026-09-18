import GalavantSchema
import SwiftUI
import UIKit

/// Where an idea sits on the active trip, in the three plain-language stages the
/// planner thinks in (dogfood): **Consider** (a maybe), **Schedule** (committed
/// to go, awaiting a day — the shortlist), **Scheduled** (placed on a day). A
/// display projection over `TripIdeaStatus` (+ whether it has a day); the core
/// keeps its richer statuses.
enum TripPullStage {
  case consider, schedule, scheduled

  var label: String {
    switch self {
    case .consider: "Consider"
    case .schedule: "Schedule"
    case .scheduled: "Scheduled"
    }
  }
}

struct IdeaRow: View {
  /// The cell's trailing trip-awareness affordance. Two modes (BACKLOG "Ideas
  /// list trip-awareness"): the eternal pool shows a derived association badge +
  /// the rating heart; an active-trip capsule turns the row into a pull surface
  /// — two plain-word menus, Vote and Status, whose labels show the current
  /// value (dogfood).
  enum TripAccessory {
    case badge(IdeaTripBadge?)
    case pull(
      stage: TripPullStage?,
      onConsider: () -> Void,
      onSchedule: () -> Void,
      onUnschedule: () -> Void,
      onClear: () -> Void
    )
  }

  let idea: Idea
  /// The header image's thumbnail bytes, when the idea has one — shown in the
  /// leading slot in place of the kind glyph (M4f). Nil → the kind icon.
  var headerThumbnail: Data? = nil
  /// The one accolade to headline on the row (dogfood #3) — a Michelin ★/🗝, a
  /// score — so a planner can weigh ideas without tapping in. Nil → no rating.
  var evaluation: IdeaEvaluation? = nil
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
      // The leading image opens the editor too, not just the text (dogfood).
      Button(action: onTap) { leadingImage }
        .buttonStyle(.plain)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 4) {
        Button(action: onTap) {
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(idea.name)
                .foregroundStyle(.primary)
              ratingPill
            }
            if let regionName = idea.regionName, !regionName.isEmpty {
              Text(regionName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            // A one-line note snippet so the deciding surface carries more than the
            // name (dogfood #4) — the user's own note, not the page description.
            if !idea.notes.isEmpty {
              Text(idea.notes)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

  /// The headline accolade as a compact capsule, shown as the source expressed it
  /// (ADR-0015: never normalized) — a Michelin ★★★ / 🗝🗝, a score. Nil-safe.
  @ViewBuilder
  private var ratingPill: some View {
    if let evaluation {
      Text(evaluation.nativeDisplay)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(.secondarySystemFill), in: Capsule())
        .foregroundStyle(.primary)
        .accessibilityLabel("\(evaluation.sourceName) rating \(evaluation.nativeDisplay)")
    }
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
  /// rating heart. Once scoped to a trip the row becomes two plain-word menus —
  /// **Vote** (the interest levels) over **Status** (Consider / Schedule /
  /// Unschedule / Clear) — each labelled with its current value (dogfood).
  @ViewBuilder
  private var trailingAccessories: some View {
    switch tripAccessory {
    case let .badge(badge):
      if let badge { TripBadgeView(badge: badge) }
      interestHeart
    case let .pull(stage, onConsider, onSchedule, onUnschedule, onClear):
      VStack(alignment: .trailing, spacing: 6) {
        voteMenu
        statusMenu(
          stage: stage,
          onConsider: onConsider,
          onSchedule: onSchedule,
          onUnschedule: onUnschedule,
          onClear: onClear)
      }
      .frame(minWidth: 92, alignment: .trailing)
    }
  }

  private var interestHeart: some View {
    InterestMenu(current: myInterest, onSelect: onSetInterest) {
      Image(systemName: myInterest == nil ? "heart" : "heart.fill")
        .foregroundStyle(myInterest == nil ? Color.secondary : Color.red)
    }
  }

  /// The Vote menu: the current planner's interest levels, its label showing the
  /// current vote (or "Vote" when unrated).
  private var voteMenu: some View {
    InterestMenu(current: myInterest, onSelect: onSetInterest) {
      menuChip(
        title: myInterest?.label ?? "Vote",
        systemImage: myInterest == nil ? "heart" : "heart.fill",
        filled: myInterest != nil,
        tint: .red)
    }
  }

  /// The Status menu: the idea's stage on the active trip. Its label shows the
  /// current stage (or "Status" when the idea isn't on the trip yet); the items
  /// are the plain-language moves — Consider, Schedule, Unschedule (only once
  /// it's on a day), Clear.
  private func statusMenu(
    stage: TripPullStage?,
    onConsider: @escaping () -> Void,
    onSchedule: @escaping () -> Void,
    onUnschedule: @escaping () -> Void,
    onClear: @escaping () -> Void
  ) -> some View {
    Menu {
      Button {
        onConsider()
      } label: {
        statusItemLabel("Consider", checked: stage == .consider)
      }
      Button {
        onSchedule()
      } label: {
        statusItemLabel("Schedule", checked: stage == .schedule)
      }
      if stage == .scheduled {
        Button("Unschedule", action: onUnschedule)
      }
      if stage != nil {
        Divider()
        Button("Clear", role: .destructive, action: onClear)
      }
    } label: {
      menuChip(
        title: stage?.label ?? "Status",
        systemImage: statusGlyph(stage),
        filled: stage != nil,
        tint: .accentColor)
    }
  }

  private func statusItemLabel(_ title: String, checked: Bool) -> some View {
    Group {
      if checked {
        Label(title, systemImage: Icon.checkmark.systemName)
      } else {
        Text(title)
      }
    }
  }

  private func statusGlyph(_ stage: TripPullStage?) -> String {
    switch stage {
    case .none: "circle.dashed"
    case .consider: "questionmark.circle"
    case .schedule: "checkmark.circle"
    case .scheduled: "calendar.badge.checkmark"
    }
  }

  /// A compact rounded chip used as a menu's label — the current value in words,
  /// so the menu reads as its state rather than a bare icon.
  private func menuChip(
    title: String,
    systemImage: String,
    filled: Bool,
    tint: Color
  ) -> some View {
    HStack(spacing: 4) {
      Image(systemName: systemImage).imageScale(.small)
      Text(title).lineLimit(1)
    }
    .font(.caption.weight(.medium))
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .foregroundStyle(filled ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
    .background(Color(.secondarySystemFill), in: Capsule())
  }
}
