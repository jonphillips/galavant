import GalavantSchema
import SwiftUI
import SwiftUINavigation

/// One trip's planning surface: a segmented Shortlist | Add. Shortlist shows the
/// ranked (reorderable) pulls plus the "considering" pile; Add shows the
/// filtered pool you pull from (ADR-0004).
struct TripPlanningView: View {
  @State private var model: TripPlanningModel

  init(trip: Trip) {
    _model = State(initialValue: TripPlanningModel(tripID: trip.id))
  }

  /// Statuses you can assign from a row's menu (post-trip `done` is a later
  /// milestone).
  private static let assignable: [TripIdeaStatus] = [
    .considering, .shortlisted, .scheduled, .skipped,
  ]

  var body: some View {
    @Bindable var model = model
    Group {
      switch model.mode {
      case .shortlist: shortlistList
      case .add: addList
      }
    }
    .navigationTitle(model.trip?.name ?? "Trip")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Mode", selection: $model.mode) {
          ForEach(TripPlanningModel.Mode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.segmented)
      }
      if model.mode == .add {
        ToolbarItem { filterMenu }
      }
      ToolbarItem {
        Button("Edit") { model.editButtonTapped() }
      }
    }
    .sheet(item: $model.destination.edit, id: \.id) { draft in
      TripFormView(draft: draft)
    }
  }

  // MARK: - Shortlist mode

  private var shortlistList: some View {
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
      if !model.shortlist.isEmpty {
        Section("Shortlist") {
          ForEach(model.shortlist) { resolved in
            row(resolved.idea, trailing: statusMenu(for: resolved.idea, current: resolved.entry.status))
          }
          .onDelete { model.deleteShortlist(at: $0) }
          .reorderable()
        }
      }
      if !model.considering.isEmpty {
        Section("Considering") {
          ForEach(model.considering) { resolved in
            row(
              resolved.idea,
              trailing: Button {
                model.setStatus(.shortlisted, for: resolved.idea)
              } label: {
                Label("Shortlist", systemImage: "star")
              }
              .buttonStyle(.borderless)
            )
          }
          .onDelete { model.deleteConsidering(at: $0) }
        }
      }
    }
    .reorderContainer(for: TripPlanningModel.Resolved.self) { difference in
      var entries = model.shortlist
      difference.apply(to: &entries)
      model.reorderShortlist(entries.map(\.id))
    }
    .overlay {
      if model.shortlist.isEmpty, model.considering.isEmpty {
        ContentUnavailableView {
          Label("Nothing pulled yet", systemImage: "tray")
        } description: {
          Text("Switch to Add to pull ideas from the pool onto this trip.")
        }
      }
    }
  }

  // MARK: - Add mode

  private var addList: some View {
    List {
      ForEach(model.filteredPool) { idea in
        let status = model.status(for: idea)
        row(
          idea,
          trailing: Group {
            if let status {
              statusMenu(for: idea, current: status)
            } else {
              Menu {
                Button("Add to Considering", systemImage: "tray.and.arrow.down") {
                  model.pull(idea)
                }
                Button("Add to Shortlist", systemImage: "star") {
                  model.pullToShortlist(idea)
                }
              } label: {
                Image(systemName: "plus.circle")
              }
            }
          }
        )
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
  }

  // MARK: - Shared rows

  private func row(_ idea: Idea, trailing: some View) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: idea.kind?.systemImage ?? "mappin.and.ellipse")
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        Text(idea.name)
        if let regionName = idea.regionName, !regionName.isEmpty {
          Text(regionName).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Spacer()
      trailing
    }
    .padding(.vertical, 2)
  }

  private func statusMenu(for idea: Idea, current: TripIdeaStatus) -> some View {
    Menu {
      ForEach(Self.assignable, id: \.self) { status in
        Button {
          model.setStatus(status, for: idea)
        } label: {
          if status == current {
            Label(status.label, systemImage: "checkmark")
          } else {
            Text(status.label)
          }
        }
      }
      Divider()
      Button("Remove from Trip", systemImage: "minus.circle", role: .destructive) {
        model.remove(idea)
      }
    } label: {
      Text(current.label).font(.subheadline).foregroundStyle(.secondary)
    }
  }

  private var filterMenu: some View {
    Menu {
      Menu("Region") {
        Button {
          model.selectedRegionID = nil
        } label: {
          checked("All regions", on: model.selectedRegionID == nil)
        }
        ForEach(model.sortedRegions) { region in
          Button {
            model.selectedRegionID = region.id
          } label: {
            checked(region.name, on: model.selectedRegionID == region.id)
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
