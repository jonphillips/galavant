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
  @State private var managingRegions = false
  @State private var managingTags = false

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
          selectedRegion: model.selectedRegion,
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
    .sheet(isPresented: $managingRegions) {
      RegionManagerView(model: model)
    }
    .sheet(isPresented: $managingTags) {
      TagManagerView(model: model)
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
        if !model.regions.isEmpty {
          Divider()
          Button("Manage Regions…", systemImage: "slider.horizontal.3") {
            managingRegions = true
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
        if !model.tags.isEmpty {
          Divider()
          Button("Manage Tags…", systemImage: "slider.horizontal.3") {
            managingTags = true
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
#Preview {
  let _ = prepareDependencies {
    try! $0.bootstrapDatabase()
  }
  NavigationStack {
    IdeasScreen()
  }
}
