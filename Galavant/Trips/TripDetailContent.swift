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
/// bottom sheet on iPhone and as the right-hand column on iPad. Every trip-screen
/// sheet is presented from `TripDetailContent`, because on iPhone the outer view is
/// already presenting it.
struct TripDetailContent: View {
  let model: TripPlanningModel
  let reconciliationModel: CalendarReconciliationModel
  let bookingRollup: TripBookingRollup
  let bookingByRow: [TripBookingRow: ResolvedBooking]
  let usesColumn: Bool
  @Binding var showingChat: Bool

  var body: some View {
    @Bindable var model = model
    Group {
      if usesColumn {
        presentationSheets
          .popover(item: $model.detailIdeaID, id: \.self) { id in
            if let idea = model.ideaForDetail(id) {
              detailView(idea)
                .frame(idealWidth: 360, idealHeight: 520)
                .presentationCompactAdaptation(.popover)
            }
          }
      } else {
        presentationSheets
          .sheet(item: $model.detailIdeaID, id: \.self) { id in
            if let idea = model.ideaForDetail(id) {
              detailView(idea)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
          }
          .chatPanel(isPresented: $showingChat, context: .trip(model.plan))
      }
    }
  }

  private var presentationSheets: some View {
    TripDetailPresentationHost(
      model: model,
      reconciliationModel: reconciliationModel,
      bookingRollup: bookingRollup
    ) {
      editorSheets
    }
  }

  private var mapSheets: some View {
    @Bindable var model = model
    return listPanel
    .sheet(item: $model.destination.mapPlaceIdea, id: \.id) { presentation in
      MapPlaceIdeaSheet(model: model, presentation: presentation)
    }
    .sheet(item: $model.destination.recommendationDetail, id: \.self) { stopID in
      UnresolvedRecommendationSheet(model: model, stopID: stopID)
    }
    .sheet(
      item: $model.destination.placeIdea, id: \.id,
      onDismiss: model.placeIdeaSheetDismissed
    ) { target in
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
    .sheet(item: $model.destination.editTripRegions, id: \.id) { draft in
      TripFormView(draft: draft, startOnRegions: true)
    }
    .sheet(item: $model.destination.sketch, id: \.id) { _ in
      TripSketchSheet(model: model)
    }
  }

  private func detailView(_ idea: Idea) -> some View {
    IdeaDetailView(
      idea: idea,
      tagNames: model.tagNames(for: idea),
      interests: model.interests(for: idea),
      evaluations: model.evaluations(for: idea),
      stopContext: model.stopContext(for: idea),
      whyOnTrip: model.rationaleForDetail(),
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
          bookingByRow: bookingByRow,
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
        // The Itinerary adds from each day's "+"; only Ideas has a tab-wide add.
        if usesColumn, model.sheetTab == .ideas {
          HStack {
            Spacer()
            TripAddButton(model: model)
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
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
      }
    }
  }
}

/// Keeps the trip's sheet chain on its detail content so the compact layout never
/// asks the already-presenting outer view to present another sheet.
private struct TripDetailPresentationHost<Content: View>: View {
  let model: TripPlanningModel
  let reconciliationModel: CalendarReconciliationModel
  let bookingRollup: TripBookingRollup
  @ViewBuilder let content: Content

  var body: some View {
    @Bindable var model = model
    content
      .sheet(
        isPresented: Binding(
          get: { model.destination?.is(\.addIdeas) ?? false },
          set: { model.destination = $0 ? .addIdeas : nil }
        )
      ) {
        AddIdeasSheet(model: model)
      }
      .sheet(
        isPresented: Binding(
          get: { model.destination?.is(\.booking) ?? false },
          set: { model.destination = $0 ? .booking : nil }
        ),
        onDismiss: model.bookingSheetDismissed
      ) {
        ToBookSheet(model: model, rollup: bookingRollup)
      }
      .sheet(
        isPresented: Binding(
          get: { model.destination?.is(\.documents) ?? false },
          set: { model.destination = $0 ? .documents : nil }
        )
      ) {
        TripDocumentsSheet(tripID: model.tripID)
      }
      .sheet(item: $model.destination.recommendationHandoff, id: \.id) { presentation in
        RecommendationHandoffSheet(model: model, session: presentation.session)
      }
      .sheet(item: $model.destination.recommendationWorkspace, id: \.id) { presentation in
        // Presented modally from a trip, so it supplies its own nav bar + Done. The
        // Evaluate section instead pushes the same view, where the nav back button
        // is the dismissal (no floating Done — it collided with the map search's ✕).
        NavigationStack {
          RecommendationWorkspaceHost(tripID: model.tripID, sessionID: presentation.sessionID)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { model.destination = nil }
              }
            }
        }
      }
      .sheet(
        isPresented: Binding(
          get: { model.destination?.is(\.startDay) ?? false },
          set: { model.destination = $0 ? .startDay : nil }
        )
      ) {
        StartDayPanel(model: model)
      }
      .sheet(
        isPresented: Binding(
          get: { model.destination?.is(\.calendarReconciliation) ?? false },
          set: { model.destination = $0 ? .calendarReconciliation : nil }
        ),
        onDismiss: model.reloadCalendarTimeAuthority
      ) {
        if let trip = model.trip {
          CalendarReconciliationSheet(
            model: reconciliationModel,
            trip: trip,
            plan: model.plan
          )
        }
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
