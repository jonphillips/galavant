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
      if !model.plan.shortlist.isEmpty {
        Section("Shortlist") {
          ForEach(model.plan.shortlist) { resolved in
            PlanningRow(content: resolved.content, subtitle: .category) {
              // Lit star = shortlisted; tap demotes it back to Considering.
              starButton(filled: true) {
                model.setStatus(.considering, for: resolved.id)
              }
            }
            .contentShape(Rectangle())
            .onTapGesture { if let idea = resolved.idea { model.showDetail(idea) } }
            .swipeActions(edge: .leading) {
              Button {
                model.sendToBeScheduled(resolved.id)
              } label: {
                Icon.schedule.label("Schedule")
              }
              .tint(.blue)
              if resolved.idea?.kind == .stay {
                Button {
                  if let idea = resolved.idea { model.stayHere(idea) }
                } label: {
                  Icon.stay.label("Stay here")
                }
                .tint(.indigo)
              }
            }
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                model.remove(resolved.id)
              } label: {
                Icon.delete.label("Remove")
              }
            }
          }
          .reorderable()
        }
      }
      if !model.plan.scheduled.isEmpty {
        Section("Scheduled") {
          ForEach(model.plan.scheduled) { resolved in
            // A scheduled stop can't be removed here — swipe to Unschedule first
            // (idea-backed: drops back to Shortlist; freeform: removes it).
            PlanningRow(content: resolved.content, subtitle: .category) { scheduledBadge(resolved.entry.schedule) }
              .contentShape(Rectangle())
              .onTapGesture { if let idea = resolved.idea { model.showDetail(idea) } }
              .swipeActions(edge: .trailing) {
                if case .freeform = resolved.content {
                  Button(role: .destructive) {
                    model.remove(resolved.id)
                  } label: {
                    Icon.delete.label("Remove")
                  }
                } else {
                  Button {
                    model.unschedule(resolved.id)
                  } label: {
                    Icon.unschedule.label("Unschedule")
                  }
                  .tint(.orange)
                }
              }
          }
        }
      }
      if !model.plan.considering.isEmpty {
        Section("Considering") {
          ForEach(model.plan.considering) { resolved in
            PlanningRow(content: resolved.content, subtitle: .category) {
              // Empty star = considering; tap promotes it to the Shortlist.
              starButton(filled: false) {
                model.setStatus(.shortlisted, for: resolved.id)
              }
            }
            .contentShape(Rectangle())
            .onTapGesture { if let idea = resolved.idea { model.showDetail(idea) } }
            .swipeActions(edge: .leading) {
              if resolved.idea?.kind == .stay {
                Button {
                  if let idea = resolved.idea { model.stayHere(idea) }
                } label: {
                  Icon.stay.label("Stay here")
                }
                .tint(.indigo)
              }
            }
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                model.remove(resolved.id)
              } label: {
                Icon.delete.label("Remove")
              }
            }
          }
        }
      }
    }
    .reorderContainer(for: ResolvedStop.self) { difference in
      var entries = model.plan.shortlist
      difference.apply(to: &entries)
      model.reorderShortlist(entries.map(\.id))
    }
    .overlay {
      if model.plan.isEmpty {
        ContentUnavailableView {
          Icon.emptyPool.label("No ideas yet")
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
      model.sheetTab = .itinerary
    } label: {
      Image(systemName: placed ? "calendar.badge.checkmark" : "calendar.badge.clock")
        .foregroundStyle(placed ? AnyShapeStyle(.green) : AnyShapeStyle(.yellow))
    }
    .buttonStyle(.borderless)
  }
}
