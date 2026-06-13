import Dependencies
import GalavantSchema
import MapKit
import SQLiteData
import SwiftUI
import SwiftUINavigation

struct IdeasScreen: View {
  @State private var model = IdeasListModel()
  @State private var mode: Mode = .list
  @State private var visibleRegion: MKCoordinateRegion?
  @State private var namingRegion = false
  @State private var regionNameDraft = ""

  enum Mode: String, CaseIterable {
    case list, map
    var systemImage: String { self == .list ? "list.bullet" : "map" }
  }

  var body: some View {
    Group {
      switch mode {
      case .list:
        ideasList
      case .map:
        PoolMapView(
          ideas: model.filteredIdeas,
          onSelect: model.ideaTapped,
          visibleRegion: $visibleRegion
        )
      }
    }
    .navigationTitle("Ideas")
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("View", selection: $mode) {
          ForEach(Mode.allCases, id: \.self) { mode in
            Image(systemName: mode.systemImage).tag(mode)
          }
        }
        .pickerStyle(.segmented)
      }
      ToolbarItem {
        filterMenu
      }
      if mode == .map {
        ToolbarItem {
          Button {
            namingRegion = true
          } label: {
            Label("Define Region", systemImage: "plus.viewfinder")
          }
          .disabled(visibleRegion == nil)
        }
      }
      ToolbarItem {
        Button {
          Task { await model.shareTravelPartyButtonTapped() }
        } label: {
          Label("Share Travel Party", systemImage: "person.2")
        }
      }
      ToolbarItem {
        Button {
          model.addIdeaButtonTapped()
        } label: {
          Label("Add Idea", systemImage: "plus")
        }
      }
    }
    .alert("Name this area", isPresented: $namingRegion) {
      TextField("Region name", text: $regionNameDraft)
      Button("Save") {
        if let region = visibleRegion {
          model.saveRegion(named: regionNameDraft, center: region.center, span: region.span)
        }
        regionNameDraft = ""
      }
      Button("Cancel", role: .cancel) { regionNameDraft = "" }
    } message: {
      Text("Save the current map area as a region you can filter by.")
    }
    .task { await model.task() }
    .sheet(item: $model.destination.form, id: \.id) { draft in
      IdeaFormView(draft: draft)
    }
    .sheet(isPresented: Binding($model.destination.identity)) {
      IdentityView(model: model)
        .interactiveDismissDisabled()
    }
    .sheet(item: $model.sharedRecord) { sharedRecord in
      CloudSharingView(sharedRecord: sharedRecord)
    }
  }

  private var filterMenu: some View {
    Menu {
      Picker("Region", selection: $model.selectedRegionID) {
        Text("All regions").tag(MapRegion.ID?.none)
        ForEach(model.regions) { region in
          Text(region.name).tag(MapRegion.ID?.some(region.id))
        }
      }
      Menu("Kinds") {
        ForEach(IdeaKind.allCases, id: \.self) { kind in
          Button {
            model.toggleKind(kind)
          } label: {
            if model.selectedKinds.contains(kind) {
              Label(kind.label, systemImage: "checkmark")
            } else {
              Text(kind.label)
            }
          }
        }
      }
      Toggle("Show visited", isOn: $model.includeVisited)
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

  private var filterSummaryBar: some View {
    HStack(spacing: 6) {
      Image(systemName: "line.3.horizontal.decrease.circle.fill")
        .foregroundStyle(.tint)
      Text("Showing \(model.filteredIdeas.count) of \(model.ideas.count) · \(model.filterSummary)")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer()
      Button("Clear") { model.clearFilters() }
        .font(.footnote)
    }
    .padding(.horizontal)
    .padding(.vertical, 6)
    .background(.bar)
  }

  private var ideasList: some View {
    List {
      ForEach(model.filteredIdeas) { idea in
        IdeaRow(
          idea: idea,
          interests: model.interests(for: idea),
          myInterest: model.myInterest(for: idea),
          onTap: { model.ideaTapped(idea) },
          onSetInterest: { model.setMyInterest($0, for: idea) }
        )
      }
      .onDelete { model.deleteIdeas(at: $0) }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if model.isFiltering {
        filterSummaryBar
      }
    }
    .overlay {
      if model.ideas.isEmpty {
        ContentUnavailableView(
          "No ideas yet",
          systemImage: "lightbulb",
          description: Text("Tap + to capture your first travel idea.")
        )
      }
    }
  }
}

private struct IdeaRow: View {
  let idea: Idea
  let interests: [(planner: Planner, level: Interest)]
  let myInterest: Interest?
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
      InterestMenu(current: myInterest, onSelect: onSetInterest) {
        Image(systemName: myInterest == nil ? "heart" : "heart.fill")
          .foregroundStyle(myInterest == nil ? Color.secondary : Color.red)
      }
    }
    .padding(.vertical, 2)
  }
}

/// First-run / new-device identity. If the travel party already has synced
/// planners, offer to *pick* one (bind this device) rather than creating a
/// duplicate (ADR-0008); otherwise capture the first planner's name.
private struct IdentityView: View {
  let model: IdeasListModel
  @State private var name = ""
  @State private var creatingNew = false

  private var showNameField: Bool {
    model.planners.isEmpty || creatingNew
  }

  var body: some View {
    NavigationStack {
      Form {
        if showNameField {
          Section {
            TextField("Your name", text: $name)
          } header: {
            Text("Who's planning?")
          } footer: {
            Text("Your ratings and notes are labeled with this name so you and your travel party can tell them apart.")
          }
        } else {
          Section {
            ForEach(model.planners) { planner in
              Button {
                model.selectPlanner(planner)
              } label: {
                HStack {
                  Text(planner.displayName).foregroundStyle(.primary)
                  Spacer()
                  Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
              }
            }
            Button("Someone new…") { creatingNew = true }
          } header: {
            Text("Who are you?")
          } footer: {
            Text("Pick yourself so your ratings show up under your name. This only sets who you are on this device.")
          }
        }
      }
      .navigationTitle("Welcome to Galavant")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if showNameField {
          ToolbarItem(placement: .confirmationAction) {
            Button("Continue") { model.createPlanner(named: name) }
              .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
          }
          if creatingNew {
            ToolbarItem(placement: .cancellationAction) {
              Button("Back") { creatingNew = false }
            }
          }
        }
      }
    }
  }
}

#Preview {
  let _ = prepareDependencies {
    try! $0.bootstrapDatabase()
  }
  NavigationStack {
    IdeasScreen()
  }
}
