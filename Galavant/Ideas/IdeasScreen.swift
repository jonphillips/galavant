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
    VStack(spacing: 0) {
      if !model.capsules.isEmpty {
        capsuleBar
      }
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
            Icon.defineRegion.label("Define Region")
          }
          .disabled(visibleRegion == nil)
        }
      }
      ToolbarItem {
        Button {
          Task { await model.shareTravelPartyButtonTapped() }
        } label: {
          Icon.travelParty.label("Share Travel Party")
        }
      }
      ToolbarItem {
        Button {
          model.addIdeaButtonTapped()
        } label: {
          Icon.add.label("Add Idea")
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

  /// The eternal pool shows each idea's derived trip badge; an active-trip
  /// capsule turns the row into a pull/shortlist surface for that trip.
  private func tripAccessory(for idea: Idea) -> IdeaRow.TripAccessory {
    if model.activeTripID == nil {
      return .badge(model.tripBadge(for: idea))
    }
    return .pull(
      status: model.activeTripStatus(for: idea),
      onConsidering: { model.tapConsideringOnActiveTrip(idea) },
      onShortlist: { model.tapShortlistOnActiveTrip(idea) }
    )
  }

  @ViewBuilder
  private func checked(_ title: String, on: Bool) -> some View {
    if on {
      Label(title, systemImage: Icon.checkmark.systemName)
    } else {
      Text(title)
    }
  }

  /// The active-trip launchpad: "All" (the eternal pool) plus a pill per in-play
  /// trip. Tapping a trip scopes the pool to its lens and turns rows into a
  /// pull/rate surface for it.
  private var capsuleBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        capsule(label: "All", tint: nil, selected: model.activeTripID == nil) {
          model.selectCapsule(nil)
        }
        ForEach(model.capsules) { trip in
          capsule(
            label: trip.name.isEmpty ? "Untitled Trip" : trip.name,
            tint: trip.certaintyStage.tint,
            selected: model.activeTripID == trip.id
          ) {
            model.selectCapsule(trip.id)
          }
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
  }

  private func capsule(
    label: String,
    tint: Color?,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let tint {
          Circle().fill(tint).frame(width: 8, height: 8)
        }
        Text(label).lineLimit(1)
      }
      .font(.subheadline)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        Capsule().fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial))
      )
      .foregroundStyle(selected ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
  }

  private var filterMenu: some View {
    Menu {
      // A trip capsule supplies the geography; the manual region picker only
      // applies to the eternal "All" pool.
      if model.activeTripID == nil {
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
            Button("Manage Regions…", systemImage: Icon.manage.systemName) {
              managingRegions = true
            }
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
          Button("Manage Tags…", systemImage: Icon.manage.systemName) {
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
          ? Icon.filterActive.systemName
          : "line.3.horizontal.decrease.circle"
      )
    }
  }

  private var filterSummaryBar: some View {
    HStack(spacing: 6) {
      Icon.filterActive.image
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
          tripAccessory: tripAccessory(for: idea),
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
          systemImage: Icon.ideas.systemName,
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
