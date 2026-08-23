import Foundation
import GalavantSchema
import SwiftUI

struct CalendarReconciliationSheet: View {
  let model: CalendarReconciliationModel
  let trip: Trip
  let plan: TripPlan
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("Calendar is authoritative for linked commitments and unmatched trip constraints. Applied updates are shared with your travel party.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        if !model.calendars.isEmpty {
          Section("Calendar to Read") {
            Picker("Calendar", selection: Binding(
              get: { model.selectedCalendarID },
              set: { id in
                model.selectCalendar(id)
                if id != nil { Task { await model.refresh(trip: trip, plan: plan) } }
              }
            )) {
              Text("Choose a Calendar").tag(String?.none)
              ForEach(model.calendars) { calendar in
                Text(calendar.title).tag(String?.some(calendar.id))
              }
            }
            .disabled(model.state == .loading)
          }
        }

        switch model.state {
        case .idle, .loading:
          Section { ProgressView("Reading shared calendars…") }
        case .accessDenied:
          Section("Calendar Access") {
            Text("Full Calendar access is unavailable. Galavant made no deletion or itinerary decision.")
          }
        case .calendarSelectionRequired:
          Section("Choose a Calendar") {
            Text("Select the one shared calendar Galavant may read. It will not inspect your other calendars.")
          }
        case let .failure(message):
          Section("Calendar Read Failed") { Text(message) }
        case .loaded, .frozen:
          candidateSections
        }
      }
      .navigationTitle("Calendar Reconciliation")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Refresh") {
            Task { await model.refresh(trip: trip, plan: plan) }
          }
          .disabled(model.state == .loading)
        }
      }
      .task(id: trip.id) { await model.refresh(trip: trip, plan: plan) }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        Task { await model.refresh(trip: trip, plan: plan) }
      }
      .sheet(item: Binding(
        get: { model.candidateForLink },
        set: { model.candidateForLink = $0 }
      )) { candidate in
        NavigationStack {
          List(ambiguousStops(in: candidate)) { stop in
            Button {
              model.candidateForLink = nil
              Task {
                guard let selectedCalendarID = model.selectedCalendarID else { return }
                await model.link(
                  candidate, to: stop, trip: trip, plan: plan, selectedCalendarID: selectedCalendarID)
              }
            } label: {
              Text(stop.content.title)
            }
          }
          .navigationTitle("Link to Stop")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel") { model.candidateForLink = nil }
            }
          }
        }
      }
    }
  }

  @ViewBuilder private var candidateSections: some View {
    let automatic = model.candidates.filter {
      if case .automatic = $0.result { true } else { false }
    }
    let proposed = model.candidates.filter {
      if case .proposed = $0.result { true } else { false }
    }
    let ambiguous = model.candidates.filter {
      if case .ambiguous = $0.result { true } else { false }
    }
    let needsTimeZone = model.candidates.filter {
      if case .unresolvedTimeZone = $0.result { true } else { false }
    }
    let unmatched = model.candidates.filter {
      if case .unmatched = $0.result { true } else { false }
    }

    if model.state == .frozen {
      Section("Calendar Reconciliation Frozen") {
        Text("This trip is complete. Its final Calendar state is preserved as history and later Calendar cleanup will not change it.")
      }
    } else if model.candidates.isEmpty {
      ContentUnavailableView("No events in this trip's dates", systemImage: "calendar")
    } else {
      if !automatic.isEmpty {
        Section("High-Confidence Matches") {
          ForEach(automatic, content: candidateRow)
        }
      }
      if !proposed.isEmpty {
        Section("Potential Matches") {
          ForEach(proposed, content: candidateRow)
        }
      }
      if !ambiguous.isEmpty {
        Section("Needs Later Review") {
          ForEach(ambiguous, content: candidateRow)
        }
      }
      if !needsTimeZone.isEmpty {
        Section("Time Zone Needs Review") {
          ForEach(needsTimeZone, content: candidateRow)
        }
      }
      if !unmatched.isEmpty {
        Section("No Itinerary Match") {
          ForEach(unmatched, content: candidateRow)
        }
      }
    }
    if !model.ignoredEvents.isEmpty {
      DisclosureGroup(
        "Ignored",
        isExpanded: Binding(
          get: { model.isShowingIgnored },
          set: { model.isShowingIgnored = $0 }))
      {
        ForEach(model.ignoredEvents) { ignored in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(ignored.title)
              Text("Dismissed for this trip.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Un-ignore") {
              Task { await model.unignore(ignored, trip: trip, plan: plan) }
            }
            .font(.caption.weight(.semibold))
          }
        }
      }
    }
    // A linked stop whose event drifted out of the trip window is surfaced as a
    // party-wide, actionable "Plan Repair" (below), not a separate device-local
    // notice — the shared repair supersedes the old informational section.
    let history = model.sharedHistory.filter { $0.tripID == trip.id }
    if !history.isEmpty {
      Section("Calendar History") {
        ForEach(history.reversed()) { entry in
          historyRow(entry)
        }
      }
    }
    let repairs = model.planRepairs.filter { $0.tripID == trip.id }
    if !repairs.isEmpty {
      Section("Plan Repair") {
        ForEach(repairs) { repair in
          planRepairRow(repair)
        }
      }
    }
  }

  private func ambiguousStops(in candidate: CalendarReconciliationCandidate) -> [ResolvedStop] {
    if case let .ambiguous(stops) = candidate.result { return stops }
    return []
  }
}
