import GalavantSchema
import SwiftUI

/// The Add-Ideas bottom sheet: the pool scoped by the trip's filter lens, each
/// row carrying the two one-tap state icons (`questionmark.bubble` = considering,
/// `star` = shortlist). Pulled up from the bottom over the Ideas tab.
struct AddIdeasSheet: View {
  let model: TripPlanningModel

  var body: some View {
    NavigationStack {
      List {
        ForEach(model.filteredPool) { idea in
          let status = model.status(for: idea)
          PlanningRow(idea: idea) {
            HStack(spacing: 18) {
              // Considering (thought bubble) and Shortlist (star) — one tap each
              // to set the state; the lit one shows where it sits. Tapping the
              // lit icon removes it from the trip.
              addToggle("questionmark.bubble", on: status == .considering) {
                model.tapConsidering(idea)
              }
              addToggle("star", on: status?.isOnShortlist == true) {
                model.tapShortlist(idea)
              }
            }
          }
        }
      }
      .overlay {
        if model.filteredPool.isEmpty {
          ContentUnavailableView {
            Label("No ideas to pull", systemImage: "lightbulb")
          } description: {
            Text(model.isFiltering ? "No pool ideas match the filter." : "Capture ideas first on the Ideas screen.")
          }
        }
      }
      .navigationTitle("Add Ideas")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { filterMenu }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { model.destination = nil }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  /// One of the two quick-state icons; lit (filled + tinted) when the row is in
  /// that state.
  private func addToggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: on ? "\(symbol).fill" : symbol)
        .imageScale(.large)
        .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
    .buttonStyle(.borderless)
  }

  private var filterMenu: some View {
    Menu {
      Menu("Regions") {
        ForEach(model.sortedRegions) { region in
          Button {
            model.toggleRegion(region.id)
          } label: {
            checked(region.name, on: model.selectedRegionIDs.contains(region.id))
          }
        }
      }
      Menu("Kinds") {
        ForEach(IdeaKind.allCases, id: \.self) { kind in
          Button {
            model.toggleKind(kind)
          } label: {
            checked(kind.label, on: model.selectedKinds.contains(kind))
          }
        }
      }
      Menu("Tags") {
        ForEach(model.sortedTags) { tag in
          Button {
            model.toggleTag(tag.id)
          } label: {
            checked(tag.name, on: model.selectedTagIDs.contains(tag.id))
          }
        }
      }
      Toggle("Show visited", isOn: Binding(get: { model.includeVisited }, set: { model.includeVisited = $0 }))
      if model.isFiltering {
        Button("Clear filters", role: .destructive) { model.clearFilters() }
      }
    } label: {
      Label(
        "Filter",
        systemImage: model.isFiltering
          ? "line.3.horizontal.decrease.circle.fill"
          : "line.3.horizontal.decrease.circle"
      )
    }
  }

  @ViewBuilder
  private func checked(_ title: String, on: Bool) -> some View {
    if on {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }
}

/// Add a shortlisted idea to the itinerary: pick the idea and either a day +
/// time of day, or leave it in the "To Be Scheduled" bucket (the default).
struct ScheduleStopSheet: View {
  let model: TripPlanningModel
  @Environment(\.dismiss) private var dismiss
  @State private var selectedIdeaID: Idea.ID?
  // 0 = the "To Be Scheduled" bucket (the default — pick a day when you're ready).
  @State private var day = 0
  @State private var dayPart: DayPart?

  var body: some View {
    NavigationStack {
      Group {
        if model.shortlistOnly.isEmpty {
          ContentUnavailableView {
            Label("Nothing to schedule", systemImage: "star")
          } description: {
            Text("Shortlist an idea first, then add it to a day here.")
          }
        } else {
          Form {
            Section("Idea") {
              ForEach(model.shortlistOnly) { resolved in
                Button {
                  selectedIdeaID = resolved.idea.id
                } label: {
                  HStack(spacing: 12) {
                    Image(systemName: resolved.idea.kind?.systemImage ?? "mappin.and.ellipse")
                      .foregroundStyle(.secondary)
                      .frame(width: 24)
                    Text(resolved.idea.name).foregroundStyle(.primary)
                    Spacer()
                    if selectedIdeaID == resolved.idea.id {
                      Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                  }
                }
              }
            }
            Section("When") {
              Picker("Day", selection: $day) {
                Text("To be scheduled").tag(0)
                ForEach(1...(model.trip?.lengthInDays ?? 1), id: \.self) { n in
                  Text(dayLabel(n, trip: model.trip)).tag(n)
                }
              }
              Picker("Time of Day", selection: $dayPart) {
                Text("Anytime").tag(DayPart?.none)
                ForEach(DayPart.allCases) { part in
                  Text(part.label).tag(DayPart?.some(part))
                }
              }
              .disabled(day == 0)
            }
          }
        }
      }
      .navigationTitle("Add Stop")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") { add() }.disabled(selectedIdeaID == nil)
        }
      }
    }
  }

  private func add() {
    guard let id = selectedIdeaID,
      let resolved = model.shortlistOnly.first(where: { $0.idea.id == id })
    else { return }
    if day == 0 {
      model.sendToBeScheduled(resolved.idea)
    } else {
      let schedule: Schedule = dayPart.map { .daypart(day, $0) } ?? .day(day)
      model.setSchedule(schedule, for: resolved.idea)
    }
    dismiss()
  }
}
