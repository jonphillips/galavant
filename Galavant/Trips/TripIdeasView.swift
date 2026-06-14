import GalavantSchema
import SwiftUI

/// The trip's Ideas tab: the pulled ideas grouped Shortlist / Scheduled /
/// Considering, with one-tap state icons (star/calendar) and swipe actions. A
/// scheduled stop can't be removed here — it's unscheduled back to the shortlist
/// first (ADR-0004). The Add button (in the parent shell) opens the pool sheet.
struct TripIdeasView: View {
  let model: TripPlanningModel

  var body: some View {
    List {
      if let trip = model.trip {
        Section {
          HStack(spacing: 6) {
            Text(trip.certaintySummary)
            Text("·")
            Text("^[\(trip.lengthInDays) day](inflect: true)")
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
      }
      if !model.shortlistOnly.isEmpty {
        Section("Shortlist") {
          ForEach(model.shortlistOnly) { resolved in
            PlanningRow(idea: resolved.idea) {
              // Lit star = shortlisted; tap demotes it back to Considering.
              starButton(filled: true) {
                model.setStatus(.considering, for: resolved.idea)
              }
            }
            .swipeActions(edge: .leading) {
              Button {
                model.sendToBeScheduled(resolved.idea)
              } label: {
                Label("Schedule", systemImage: "calendar.badge.plus")
              }
              .tint(.blue)
            }
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                model.remove(resolved.idea)
              } label: {
                Label("Remove", systemImage: "trash")
              }
            }
          }
          .reorderable()
        }
      }
      if !model.scheduledStops.isEmpty {
        Section("Scheduled") {
          ForEach(model.scheduledStops) { resolved in
            // A scheduled stop can't be removed here — swipe to Unschedule first
            // (it drops back to the Shortlist, where Remove is available again).
            PlanningRow(idea: resolved.idea) { scheduledBadge(resolved.entry.schedule) }
              .swipeActions(edge: .trailing) {
                Button {
                  model.unschedule(resolved.idea)
                } label: {
                  Label("Unschedule", systemImage: "calendar.badge.minus")
                }
                .tint(.orange)
              }
          }
        }
      }
      if !model.considering.isEmpty {
        Section("Considering") {
          ForEach(model.considering) { resolved in
            PlanningRow(idea: resolved.idea) {
              // Empty star = considering; tap promotes it to the Shortlist.
              starButton(filled: false) {
                model.setStatus(.shortlisted, for: resolved.idea)
              }
            }
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                model.remove(resolved.idea)
              } label: {
                Label("Remove", systemImage: "trash")
              }
            }
          }
        }
      }
    }
    .reorderContainer(for: TripPlanningModel.Resolved.self) { difference in
      var entries = model.shortlistOnly
      difference.apply(to: &entries)
      model.reorderShortlist(entries.map(\.id))
    }
    .overlay {
      if model.hasNoPlanningItems {
        ContentUnavailableView {
          Label("No ideas yet", systemImage: "tray")
        } description: {
          Text("Tap + to pull ideas from the pool onto this trip.")
        } actions: {
          Button("Add Ideas") { model.addIdeasButtonTapped() }
        }
      }
    }
  }

  /// A lit (shortlisted) or outline (considering) star that flips the row's
  /// state in one tap.
  private func starButton(filled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: filled ? "star.fill" : "star")
        .foregroundStyle(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
    .buttonStyle(.borderless)
  }

  /// The lit indicator for a scheduled stop; tapping jumps to the Itinerary.
  /// Green + check once it's placed on a day, yellow + clock while it's still in
  /// the To-Be-Scheduled bucket (committed to the trip but dayless).
  private func scheduledBadge(_ schedule: Schedule) -> some View {
    let placed = schedule.dayNumber != nil
    return Button {
      model.mode = .itinerary
    } label: {
      Image(systemName: placed ? "calendar.badge.checkmark" : "calendar.badge.clock")
        .foregroundStyle(placed ? AnyShapeStyle(.green) : AnyShapeStyle(.yellow))
    }
    .buttonStyle(.borderless)
  }
}
