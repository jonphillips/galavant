import Dependencies
import GalavantChat
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
  @State private var showingChat = false
  /// The idea whose map pin was last tapped — the list scrolls to and highlights
  /// its row, so the pin and the row read as one selection.
  @State private var focusedIdeaID: Idea.ID?

  enum Mode: String, CaseIterable {
    case list, map
    var systemImage: String { self == .list ? "list.bullet" : "map" }
  }

  var body: some View {
    VStack(spacing: 0) {
      if !model.capsules.isEmpty {
        capsuleBar
      }
      quickFilterBar
      // The chat inspector is attached *inside* the toolbar-bearing view, not on the
      // whole screen: an `.inspector` on the detail-root content swallows that view's
      // `.toolbar` on iPad (the items silently vanish). Nesting it below the toolbar
      // host keeps both. (docs/KNOWN-ISSUES.md)
      content
        .chatPanel(isPresented: $showingChat, context: .pool(poolChatContext))
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
        IdeasFilterMenu(model: model, managingRegions: $managingRegions)
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
          model.addIdeaButtonTapped()
        } label: {
          Icon.add.label("Add Idea")
        }
      }
      // Discuss the current shopping surface with the model (ADR-0017).
      ToolbarItem {
        Button {
          showingChat = true
        } label: {
          Icon.chat.label("Discuss")
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
    .onAppear {
      Task { await model.reloadAfterExternalWrite() }
    }
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
    .sheet(item: $model.destination.form) { presentation in
      IdeaFormView(
        draft: presentation.draft,
        searchRegions: presentation.searchRegions
      )
    }
    .sheet(isPresented: Binding($model.destination.identity)) {
      IdentityView(model: model)
        .interactiveDismissDisabled()
    }
    .sheet(isPresented: $managingRegions) {
      RegionManagerView(model: model)
    }
  }

  /// The pool the chat is "looking at" (ADR-0017 §2): the active lens label plus
  /// the ideas currently visible under it.
  private var poolChatContext: PoolContext {
    let lens: String
    if let tripID = model.activeTripID,
      let trip = model.capsules.first(where: { $0.id == tripID })
    {
      lens = trip.name.isEmpty ? "Active trip" : trip.name
    } else {
      lens = "All ideas"
    }
    return PoolContext(lens: lens, ideas: model.filteredIdeas)
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
      placeSelectionPolicy: horizontalSizeClass == .regular
        ? .exploreFirst(.popover)
        : .exploreFirst(.sheet),
      onSelect: pinTapped,
      onSelectMapPlace: model.mapPlaceTapped,
      visibleRegion: $visibleRegion
    )
  }

  /// A pin tap finds the idea in the list (scrolled to and highlighted, beside the
  /// map on iPad) and opens its detail, the same as tapping the row.
  private func pinTapped(_ idea: Idea) {
    focusedIdeaID = idea.id
    model.ideaTapped(idea)
  }

  /// The one-tap browse filters and the active trip's optional region narrowing.
  private var quickFilterBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        if model.activeTripID != nil, model.tripSubregions.count >= 2 {
          ForEach(model.tripSubregions) { region in
            IdeasQuickFilterChip(
              label: region.name,
              systemImage: Icon.map.systemName,
              isSelected: model.selectedSubregionIDs.contains(region.id)
            ) {
              model.toggleSubregion(region.id)
            }
          }
          quickFilterDivider
        }
        ForEach(IdeaKindGroup.allCases, id: \.self) { group in
          IdeasQuickFilterChip(
            label: group.label,
            systemImage: group.systemImage,
            isSelected: model.selectedKindGroups.contains(group)
          ) {
            model.toggleKindGroup(group)
          }
        }
        if model.activeTripID != nil {
          quickFilterDivider
          IdeasQuickFilterChip(
            label: IdeasListModel.ScheduleFilter.scheduled.label,
            systemImage: "calendar",
            isSelected: model.scheduleFilter == .scheduled
          ) {
            model.toggleScheduleFilter(.scheduled)
          }
          IdeasQuickFilterChip(
            label: IdeasListModel.ScheduleFilter.notScheduled.label,
            systemImage: "calendar.badge.clock",
            isSelected: model.scheduleFilter == .notScheduled
          ) {
            model.toggleScheduleFilter(.notScheduled)
          }
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
  }

  private var quickFilterDivider: some View {
    Divider()
      .frame(height: 20)
      .padding(.horizontal, 2)
  }

  /// The eternal pool shows each idea's derived trip badge; an active-trip
  /// capsule turns the row into a pull/shortlist surface for that trip.
  private func tripAccessory(for idea: Idea) -> IdeaRow.TripAccessory {
    if model.activeTripID == nil {
      return .badge(model.tripBadge(for: idea))
    }
    return .pull(
      stage: model.activeTripStage(for: idea),
      onConsider: { model.considerOnActiveTrip(idea) },
      onSchedule: { model.scheduleOnActiveTrip(idea) },
      onUnschedule: { model.unscheduleOnActiveTrip(idea) },
      onClear: { model.clearFromActiveTrip(idea) }
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
    ScrollViewReader { proxy in
      ideaRows
        .onChange(of: focusedIdeaID) { _, id in scroll(proxy, to: id) }
        // iPhone swaps list and map, so the list may appear after the pin tap.
        .onAppear { scroll(proxy, to: focusedIdeaID) }
    }
  }

  private func scroll(_ proxy: ScrollViewProxy, to id: Idea.ID?) {
    guard let id else { return }
    withAnimation { proxy.scrollTo(id, anchor: .center) }
  }

  private var ideaRows: some View {
    let tagIndex = model.tagIndex
    return List {
      ForEach(model.filteredIdeas(using: tagIndex)) { idea in
        IdeaRow(
          idea: idea,
          headerThumbnail: model.headerThumbnailByIdea[idea.id],
          evaluation: model.headlineEvaluationByIdea[idea.id],
          tagNames: tagIndex.names(for: idea.id),
          interests: model.ratingRow(for: idea),
          isMatch: model.isMatch(idea),
          myInterest: model.myInterest(for: idea),
          tripAccessory: tripAccessory(for: idea),
          onTap: { model.ideaTapped(idea) },
          onSetInterest: { model.setMyInterest($0, for: idea) }
        )
        .id(idea.id)
        .listRowBackground(
          focusedIdeaID == idea.id ? Color.accentColor.opacity(0.15) : nil)
      }
      .onDelete { model.deleteIdeas(model.filteredIdeas(using: tagIndex), at: $0) }
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

private struct IdeasQuickFilterChip: View {
  let label: String
  let systemImage: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
          .imageScale(.small)
          .accessibilityHidden(true)
        Text(label).lineLimit(1)
      }
      .font(.subheadline)
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(
        Capsule().fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial))
      )
      .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
