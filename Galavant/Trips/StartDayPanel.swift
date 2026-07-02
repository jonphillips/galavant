import GalavantSchema
import SwiftUI

/// The start-day solver panel (ADR-0029 §5): because the itinerary is day-relative,
/// the start weekday is a free variable — this shows, for each of the seven candidate
/// starts, how many keyed food/place stops would land on a day they're closed or not
/// serving the wanted meal. **Advisory only** (ADR-0004): it never moves a stop or
/// changes the start; it *shows* which starts are clean. Stops with unknown hours
/// simply don't constrain, so the panel degrades gracefully before hours coverage is
/// complete.
struct StartDayPanel: View {
  let model: TripPlanningModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if model.startDaySolverStops.isEmpty {
          emptyState
        } else {
          content
        }
      }
      .navigationTitle("Start-Day Check")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var content: some View {
    List {
      Section {
        ForEach(model.startDayOptions) { option in
          StartDayOptionRow(
            option: option,
            isCurrent: option.startWeekday == model.currentStartWeekday,
            verifiedAt: model.stopHoursVerifiedAt
          )
        }
      } footer: {
        Text(
          "Advisory only — this never moves a stop or changes your dates. "
            + "Stops with unknown hours don't constrain the start."
        )
      }
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No hours to check yet", systemImage: "clock.badge.questionmark")
    } description: {
      Text(
        "Add structured weekly hours to scheduled stops (in each idea's form) to see "
          + "which start days keep every stop open for the meal you planned."
      )
    }
  }
}

/// One candidate start weekday: a clean/conflict badge, the current-start marker, and
/// the offending stops when it isn't clean.
private struct StartDayOptionRow: View {
  let option: StartDayOption
  let isCurrent: Bool
  let verifiedAt: [TripIdea.ID: Date]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Start \(option.startWeekday.label)")
          .font(.headline)
        if isCurrent {
          Text("Current")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
        }
        Spacer()
        badge
      }
      ForEach(option.conflicts) { conflict in
        VStack(alignment: .leading, spacing: 1) {
          Text(conflict.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
          if let date = verifiedAt[conflict.stopID] {
            Text("hours as of \(date.formatted(date: .abbreviated, time: .omitted))")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder private var badge: some View {
    if option.isClean {
      Label("All open", systemImage: "checkmark.circle.fill")
        .font(.caption.bold())
        .foregroundStyle(.green)
        .labelStyle(.titleAndIcon)
    } else {
      let count = option.conflicts.count
      Label("\(count) conflict\(count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
        .font(.caption.bold())
        .foregroundStyle(.orange)
        .labelStyle(.titleAndIcon)
    }
  }
}
