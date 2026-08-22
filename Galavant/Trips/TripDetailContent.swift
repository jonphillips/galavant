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
/// bottom sheet on iPhone and as the right-hand column on iPad. Row-triggered
/// sheets are presented here so they stack above either layout; toolbar-triggered
/// sheets remain on the outer presentation host.
struct TripDetailContent: View {
  let model: TripPlanningModel
  let reconciliationModel: CalendarReconciliationModel
  let usesColumn: Bool
  var onShowStartDay: () -> Void = {}
  var onShowCalendarReconciliation: () -> Void = {}

  var body: some View {
    @Bindable var model = model
    Group {
      if usesColumn {
        editorSheets
          .popover(item: $model.detailIdeaID, id: \.self) { id in
            if let idea = model.ideaForDetail(id) {
              detailView(idea)
                .frame(idealWidth: 360, idealHeight: 520)
                .presentationCompactAdaptation(.popover)
            }
          }
      } else {
        editorSheets
          .sheet(item: $model.detailIdeaID, id: \.self) { id in
            if let idea = model.ideaForDetail(id) {
              detailView(idea)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
          }
      }
    }
  }

  private var mapSheets: some View {
    @Bindable var model = model
    return listPanel
    .sheet(item: $model.destination.mapPlaceIdea, id: \.id) { presentation in
      MapPlaceIdeaSheet(model: model, presentation: presentation)
    }
    .sheet(item: $model.destination.placeIdea, id: \.id) { target in
      PlaceIdeaSheet(model: model, target: target)
    }
  }

  private var editorSheets: some View {
    @Bindable var model = model
    return mapSheets
    .sheet(item: $model.destination.idea, id: \.id) { presentation in
      IdeaFormView(draft: presentation.draft)
    }
    .sheet(item: $model.destination.freeformStop, id: \.id) { draft in
      FreeformStopSheet(model: model, draft: draft)
    }
    .sheet(item: $model.destination.alternativeSource, id: \.id) { target in
      AlternativeSourceSheet(model: model, target: target)
    }
    .sheet(item: $model.destination.alternativeSlot, id: \.id) { target in
      AlternativeSlotSheet(model: model, target: target)
    }
    .sheet(item: $model.destination.stay, id: \.id) { draft in
      StaySheet(model: model, draft: draft)
    }
    .sheet(item: $model.destination.stopTime, id: \.id) { draft in
      StopTimeSheet(model: model, draft: draft)
    }
    .sheet(item: $model.destination.stopEditor, id: \.id) { draft in
      StopEditorSheet(model: model, draft: draft)
    }
  }

  private func detailView(_ idea: Idea) -> some View {
    IdeaDetailView(
      idea: idea,
      tagNames: model.tagNames(for: idea),
      interests: model.interests(for: idea),
      evaluations: model.evaluations(for: idea),
      stopContext: model.stopContext(for: idea),
      headerImage: model.headerThumbnailByIdea[idea.id])
  }

  private var listPanel: some View {
    @Bindable var model = model
    return Group {
      switch model.sheetTab {
      case .itinerary:
        TripItineraryView(
          model: model,
          reconciliationModel: reconciliationModel,
          showsInlineAdd: !usesColumn,
          focusedDay: model.canvasSelectedDay
        )
      case .ideas:
        TripIdeasView(model: model, showsInlineAdd: !usesColumn, usesColumn: usesColumn)
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
