import GalavantSchema
import SwiftUI
import SwiftUINavigation

/// The list-based second projection of the trip canvas (M3d) — the same shared
/// selection as the map, shown as a list. A segmented control swaps between the
/// **Itinerary** (the day timeline, focused to the day chip's lens) and **Ideas**
/// (the pulled pool: Shortlist / Scheduled / Considering). The context-sensitive
/// Add lives in its top bar; trip administration lives in Edit Trip from the
/// Trips collection.
///
/// This content is layout-agnostic: `TripPlanningView` hosts it as the persistent
/// bottom sheet on iPhone and as the right-hand column on iPad. The modal sheets
/// (edit form, Add-Ideas pool, Add Stop) are presented by the host so they stack
/// above either layout.
struct TripDetailContent: View {
  let model: TripPlanningModel
  let usesColumn: Bool
  var onShowStartDay: () -> Void = {}
  var onShowCalendarReconciliation: () -> Void = {}

  var body: some View {
    @Bindable var model = model
    // The read-only detail drills down *within this panel* (the iPhone bottom
    // sheet / the iPad right column) so it never covers the map. It's an opaque
    // overlay swap keyed on `detailIdeaID`, deliberately *not* a nested
    // `NavigationStack`: nesting one inside the iPad `NavigationSplitView`'s detail
    // stack made the trip push pop straight back. This works identically on both
    // platforms and leaves the list chrome untouched.
    ZStack {
      listPanel
      if let id = model.detailIdeaID, let idea = model.ideaForDetail(id) {
        detailPanel(idea)
          .transition(.move(edge: .trailing))
          .zIndex(1)
      }
    }
    .animation(.snappy, value: model.detailIdeaID)
    .sheet(item: $model.destination.mapPlaceIdea, id: \.id) { presentation in
      MapPlaceIdeaSheet(model: model, presentation: presentation)
    }
  }

  /// The drilled-in detail with its own back header (chevron labelled with the
  /// list it came from), opaque so it reads as a push over the list.
  private func detailPanel(_ idea: Idea) -> some View {
    VStack(spacing: 0) {
      HStack {
        Button { model.detailIdeaID = nil } label: {
          Label(model.sheetTab.label, systemImage: "chevron.backward")
        }
        Spacer()
      }
      .overlay { Text(idea.name).font(.headline).lineLimit(1) }
      .padding(.horizontal)
      .padding(.vertical, 10)
      .background(.bar)
      IdeaDetailView(
        idea: idea,
        tagNames: model.tagNames(for: idea),
        interests: model.interests(for: idea),
        evaluations: model.evaluations(for: idea),
        stopContext: model.stopContext(for: idea)
      )
    }
    .background(.background)
  }

  private var listPanel: some View {
    @Bindable var model = model
    return Group {
      switch model.sheetTab {
      case .itinerary:
        TripItineraryView(
          model: model,
          showsInlineAdd: !usesColumn,
          focusedDay: model.canvasSelectedDay
        )
      case .ideas:
        TripIdeasView(model: model, showsInlineAdd: !usesColumn)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        // The trip's "romance" header remains part of the planning column, but
        // not the compact in-trip surface where vertical space is scarce.
        if usesColumn, let header = model.trip?.headerImage {
          TripHeaderImageView(image: header)
        }
        if usesColumn {
          HStack {
            Spacer()
            TripAddButton(model: model, tab: model.sheetTab)
          }
          .padding(.horizontal)
          .padding(.vertical, 8)
          .background(.bar)
        }
        // The Itinerary/Ideas switcher, pinned at the top of the content area so
        // it stays put while the list scrolls.
        HStack(spacing: 8) {
          Picker("View", selection: $model.sheetTab) {
            ForEach(TripPlanningModel.SheetTab.allCases) { tab in
              Text(tab.label).tag(tab)
            }
          }
          .pickerStyle(.segmented)
          tripSettingsMenu
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
      }
    }
  }

  @ViewBuilder private var tripSettingsMenu: some View {
    if !model.startDaySolverStops.isEmpty || model.trip?.certainty.stage == .dated {
      Menu {
        if !model.startDaySolverStops.isEmpty {
          Button(action: onShowStartDay) {
            Label("Start Day", systemImage: "calendar.day")
          }
        }
        if model.trip?.certainty.stage == .dated {
          Button(action: onShowCalendarReconciliation) {
            Label("Reconcile Calendar", systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .imageScale(.large)
      }
      .accessibilityLabel("Trip settings")
    }
  }
}

private struct MapPlaceIdeaSheet: View {
  let model: TripPlanningModel
  let presentation: MapPlaceIdea

  var body: some View {
    IdeaFormView(
      draft: presentation.draft,
      searchRegions: model.tripRegions,
      saveTitle: "Save & Add to Trip"
    ) { ideaID in
      await model.mapPlaceIdeaSaved(ideaID)
    }
  }
}
