import Dependencies
import GalavantSchema
import MapKit
import SQLiteData
import SwiftUI
import SwiftUINavigation

struct IdeasScreen: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(AppRouter.self) private var router
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
      // The active trip's subregions, to steer the browse (ADR-0013) — only worth
      // showing once a trip spans 2+ regions.
      if model.activeTripID != nil, model.tripSubregions.count >= 2 {
        subregionBar
      }
      content
    }
    .navigationTitle("Ideas")
    // Consume an itinerary "Browse ideas for this day" hand-off (ADR-0013): scope to
    // the trip, pre-toggle the day's region, and show the map. `initial: true` covers
    // the split-view case where this screen is freshly built on selection.
    .onChange(of: router.ideasScope?.id, initial: true) { applyIdeasScope() }
    .toolbar {
      // Regular width shows list + map together (ADR-0013); the list/map toggle is
      // only for compact, where they swap.
      if horizontalSizeClass == .compact {
        ToolbarItem(placement: .principal) {
          Picker("View", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { mode in
              Image(systemName: mode.systemImage).tag(mode)
            }
          }
          .pickerStyle(.segmented)
        }
      }
      ToolbarItem {
        IdeasFilterMenu(
          model: model, managingRegions: $managingRegions, managingTags: $managingTags)
      }
      // Define Region whenever a map is on screen (always on regular, map mode on compact).
      if horizontalSizeClass == .regular || mode == .map {
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
    .task {
      // Take the deferred second enrichment hop for freshly captured ideas (M4g).
      await model.enrichPendingIdeas()
    }
    .task {
      // A share-extension capture commits in another process; pick it up live, then
      // enrich the new arrival.
      for await _ in DatabaseChange.notifications {
        await model.reloadAfterExternalWrite()
        await model.enrichPendingIdeas()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      // And whenever we return to the foreground (the common path: app was
      // backgrounded while the share sheet was up).
      if phase == .active {
        Task {
          await model.reloadAfterExternalWrite()
          await model.enrichPendingIdeas()
        }
      }
    }
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

  /// The browse body: list + map side-by-side on iPad (regular width, ADR-0013 —
  /// the cavern fix; Jon wants pins always in view), the list/map toggle on iPhone.
  @ViewBuilder private var content: some View {
    if horizontalSizeClass == .regular {
      HStack(spacing: 0) {
        ideasList
          .frame(maxWidth: 420)
        Divider()
        poolMap
      }
    } else {
      switch mode {
      case .list: ideasList
      case .map: poolMap
      }
    }
  }

  /// Apply a pending itinerary hand-off (ADR-0013): select the trip's capsule,
  /// pre-toggle the day's region, surface the map, then clear the request.
  private func applyIdeasScope() {
    guard let scope = router.ideasScope else { return }
    model.selectCapsule(scope.tripID)
    if let regionID = scope.regionID {
      model.selectedSubregionIDs = [regionID]
    }
    mode = .map
    router.ideasScope = nil
  }

  private var poolMap: some View {
    PoolMapView(
      ideas: model.filteredIdeas,
      framingRegions: model.framingRegions,
      pulledIDs: model.activeTripIdeaIDs,
      onSelect: model.ideaTapped,
      visibleRegion: $visibleRegion
    )
  }

  /// The active trip's subregions as opt-in narrowing chips (ADR-0013). None on =
  /// the trip's full union; toggling some narrows the list and the map's framing.
  private var subregionBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(model.tripSubregions) { region in
          subregionChip(region)
        }
      }
      .padding(.horizontal)
      .padding(.bottom, 8)
    }
  }

  private func subregionChip(_ region: MapRegion) -> some View {
    let on = model.selectedSubregionIDs.contains(region.id)
    return Button {
      model.toggleSubregion(region.id)
    } label: {
      HStack(spacing: 5) {
        Icon.map.image.imageScale(.small)
        Text(region.name).lineLimit(1)
      }
      .font(.subheadline)
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(Capsule().fill(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial)))
      .foregroundStyle(on ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
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
          headerThumbnail: model.headerThumbnailByIdea[idea.id],
          interests: model.ratingRow(for: idea),
          isMatch: model.isMatch(idea),
          myInterest: model.myInterest(for: idea),
          tripAccessory: tripAccessory(for: idea),
          onTap: { model.ideaTapped(idea) },
          onSetInterest: { model.setMyInterest($0, for: idea) }
        )
      }
      .onDelete { model.deleteIdeas(model.filteredIdeas, at: $0) }
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
  .environment(AppRouter())
}
