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
            Icon.ideas.label("No ideas to pull")
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
          ? Icon.filterActive.systemName
          : "line.3.horizontal.decrease.circle"
      )
    }
  }

  @ViewBuilder
  private func checked(_ title: String, on: Bool) -> some View {
    if on {
      Label(title, systemImage: Icon.checkmark.systemName)
    } else {
      Text(title)
    }
  }
}

/// Drop a shortlisted idea into one itinerary section — a specific day, or the
/// To Be Scheduled bucket — chosen by that section's "+". The day is fixed by
/// the target, so adding is a single tap: tap an idea and it lands (anytime on
/// that day; refine the time later via `StopMenu`). Freeform stops are never
/// shortlisted (ADR-0010), so every row here is idea-backed.
struct PlaceIdeaSheet: View {
  let model: TripPlanningModel
  let target: PlaceIdeaTarget
  @Environment(\.dismiss) private var dismiss

  private var sectionLabel: String {
    target.day.map { dayLabel($0, trip: model.trip) } ?? "To Be Scheduled"
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.plan.shortlist.isEmpty {
          ContentUnavailableView {
            Icon.shortlist.label("Nothing to add")
          } description: {
            Text("Shortlist an idea first, then drop it onto a day here.")
          }
        } else {
          List {
            ForEach(model.plan.shortlist) { resolved in
              Button {
                model.placeIdea(resolved.id, on: target.day)
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: resolved.content.idea?.kind?.systemImage ?? "mappin.and.ellipse")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                  Text(resolved.content.title).foregroundStyle(.primary)
                  Spacer()
                }
              }
            }
          }
        }
      }
      .navigationTitle("Add to \(sectionLabel)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

/// Author or edit a freeform itinerary stop — a custom stop with no pool idea
/// ("lunch", "train to Aarhus", "check in"). One sheet for both. When creating,
/// a day picker (default: To Be Scheduled) lands it directly; when editing, only
/// the content changes — day placement is the `StopMenu`'s job, as for any stop
/// (ADR-0010 Slice 3). The title is required; the note is optional.
struct FreeformStopSheet: View {
  let model: TripPlanningModel
  @State private var draft: FreeformStopDraft
  @Environment(\.dismiss) private var dismiss
  @FocusState private var titleFocused: Bool

  init(model: TripPlanningModel, draft: FreeformStopDraft) {
    self.model = model
    _draft = State(initialValue: draft)
  }

  private var isEditing: Bool { draft.stopID != nil }
  private var canSave: Bool {
    !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Stop") {
          TextField("Title", text: $draft.title)
            .focused($titleFocused)
        }
        Section("Note") {
          TextField("Optional details", text: $draft.note, axis: .vertical)
            .lineLimit(2...5)
        }
        // Placement is offered only at create time; editing leaves it to the
        // StopMenu, as for any stop.
        if !isEditing {
          Section("When") {
            Picker("Day", selection: $draft.day) {
              Text("To Be Scheduled").tag(Int?.none)
              ForEach(1...(model.trip?.lengthInDays ?? 1), id: \.self) { n in
                Text(dayLabel(n, trip: model.trip)).tag(Int?.some(n))
              }
            }
          }
        }
      }
      .navigationTitle(isEditing ? "Edit Stop" : "Add Custom Stop")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isEditing ? "Save" : "Add") { model.saveFreeform(draft) }.disabled(!canSave)
        }
      }
      .onAppear { titleFocused = !isEditing }
    }
    .presentationDetents([.medium])
  }
}
