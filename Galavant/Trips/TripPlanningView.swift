import GalavantChat
import GalavantSchema
import SwiftUI
import SwiftUINavigation

/// One trip's planning surface, map-first (M3d, docs/trip-canvas.md): the home is
/// the **canvas** — a map of the scheduled stops with day chips on top. The list
/// surfaces (`TripDetailContent`: Itinerary timeline + Ideas pool) are the second
/// projection of the same selection, and here the platforms diverge:
///
/// - **iPhone (compact):** a persistent Apple-Maps-style bottom sheet over a
///   full-bleed map.
/// - **iPad (regular):** a solid right-hand column beside the map, so the map and
///   the itinerary can be panned/scrolled at the same time while planning.
///
/// The context Add lives on the sheet/column; the modal sheets are presented
/// from here so they stack over either layout.
struct TripPlanningView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(AppRouter.self) private var router
  let trip: Trip
  /// The trip's planning model, cached on the router so the in-trip state (day lens,
  /// sheet tab, selection) survives flipping to Ideas and back (the iPad detail
  /// rebuilds on screen change).
  private var model: TripPlanningModel { router.planningModel(for: trip) }
  @State private var showDetailSheet = false
  @State private var showingChat = false
  @State private var showingStartDay = false
  /// M7's local, read-only reconciliation view. Its results never leave this
  /// per-view model until later slices prove the durable authority semantics.
  @State private var showingCalendarReconciliation = false
  @State private var calendarReconciliationModel = CalendarReconciliationModel()
  @State private var sheetDetent: PresentationDetent = .medium
  /// Measured heights of the full-bleed map and the bottom sheet over it — their
  /// ratio is the southern slice of the map the sheet hides, fed to the canvas so
  /// a revealed pin lands above the sheet (iPhone only). Measured, not derived
  /// from the detent, because the system detents (`.medium`/`.large`) are only
  /// approximable as points (docs/BACKLOG.md).
  @State private var mapHeight: CGFloat = 0
  @State private var sheetHeight: CGFloat = 0

  /// The resting peek height — leaves most of the map (and the day chips) visible.
  private static let peek: PresentationDetent = .height(120)
  /// The iPad detail column width — wide enough for itinerary rows to read.
  private static let columnWidth: CGFloat = 380

  /// iPad/Mac get the side column; iPhone (and a narrow iPad split) get the sheet.
  private var usesColumn: Bool { horizontalSizeClass == .regular }

  /// The fraction of the map the sheet covers, for the canvas's reveal inset:
  /// zero on the column layout (map unobscured), else the measured ratio, capped
  /// so the unobscured band never collapses (`.large` ≈ full-screen sheet).
  private var bottomInsetFraction: Double {
    guard !usesColumn, mapHeight > 0 else { return 0 }
    return min(Double(sheetHeight / mapHeight), 0.6)
  }

  var body: some View {
    @Bindable var model = model
    CalendarReconciliationPresentationHost(
      model: model,
      reconciliationModel: calendarReconciliationModel,
      isPresented: $showingCalendarReconciliation
    ) {
      TripPlanningPresentationHost(model: model, showingStartDay: $showingStartDay) {
        layout
      // Inspector nested *below* the toolbar host: an `.inspector` applied outside a
      // toolbar-bearing view swallows its `.toolbar` on iPad (docs/KNOWN-ISSUES.md).
      .chatPanel(isPresented: $showingChat, context: .trip(model.plan))
      .navigationTitle(model.trip?.name ?? "Trip")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            model.startRecommendationHandoff()
          } label: {
            Icon.recommend.label("Recommend")
          }
        }
        // Discuss this trip's itinerary with the model (ADR-0017).
        ToolbarItem {
          Button {
            showingChat = true
          } label: {
            Icon.chat.label("Discuss")
          }
        }
      }
      .task {
        model.pickInitialSheetTabIfNeeded()
        model.seedLensIfNeeded()
        // Present the persistent sheet on appear (compact only) — `.constant(true)`
        // is unreliable on a NavigationStack push.
        if !usesColumn { showDetailSheet = true }
        await model.fetchMissingETAs()
      }
      .onChange(of: model.plan.allLegs) { _, _ in
        Task { await model.fetchMissingETAs() }
      }
      .onChange(of: model.tripRegionIDs) { _, _ in model.reseedLens() }
      .onChange(of: model.canvasSelectedStopID) { _, id in
        handleCanvasSelection(id)
      }
      .onChange(of: model.detailIdeaID) { _, id in
        // Drilling into a stop's detail pushes within the sheet — raise it off the
        // peek so the pushed panel has room to read (iPhone only).
        guard id != nil, !usesColumn, sheetDetent == Self.peek else { return }
        sheetDetent = .medium
      }
      }
    }
  }

  /// Surface the itinerary when a map pin selects a stop. Keeping this out of the
  /// modifier closure avoids an Xcode 27 type-checker timeout in the large view
  /// builder above.
  private func handleCanvasSelection(_ id: TripIdea.ID?) {
    guard id != nil else { return }
    // A selected stop lives on the Itinerary, so surface that tab — otherwise
    // tapping a pin while on Ideas would scroll a list it isn't in.
    model.sheetTab = .itinerary
    // On iPhone, nudge the sheet up from its peek so the timeline shows.
    if !usesColumn, sheetDetent == Self.peek { sheetDetent = .medium }
  }

  @ViewBuilder private var layout: some View {
    if usesColumn {
      columnLayout
    } else {
      sheetLayout
    }
  }

  /// iPad: map on the left, a solid detail column on the right — both live at once,
  /// no translucent overlay.
  private var columnLayout: some View {
    HStack(spacing: 0) {
      canvas
      Divider()
      TripDetailContent(
        model: model,
        usesColumn: usesColumn,
        onShowStartDay: { showingStartDay = true },
        onShowCalendarReconciliation: { showingCalendarReconciliation = true }
      )
        .frame(width: Self.columnWidth)
        .background(.background)
    }
    .ignoresSafeArea(.container, edges: .bottom)
  }

  /// iPhone: full-bleed map under a persistent, Apple-Maps-style bottom sheet.
  private var sheetLayout: some View {
    canvas
      .ignoresSafeArea(.container, edges: .bottom)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mapHeight = $0 }
      .sheet(isPresented: $showDetailSheet) {
        TripDetailContent(
          model: model,
          usesColumn: usesColumn,
          onShowStartDay: { showingStartDay = true },
          onShowCalendarReconciliation: { showingCalendarReconciliation = true }
        )
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
          .presentationDetents([Self.peek, .medium, .large], selection: $sheetDetent)
          .presentationBackgroundInteraction(.enabled(upThrough: .medium))
          .presentationContentInteraction(.scrolls)
          .interactiveDismissDisabled()
          .presentationDragIndicator(.visible)
      }
  }

  /// The map plus its day-chip lens — the left/full-bleed surface in both layouts.
  private var canvas: some View {
    TripCanvasMapView(model: model, bottomInsetFraction: bottomInsetFraction)
      .safeAreaInset(edge: .top, spacing: 0) { DayChipBar(model: model) }
  }
}

/// Extracted from the planning host's modifier chain so the Xcode beta compiler
/// can type-check the map-first sheet alongside the existing reconciliation UI.
private struct CalendarReconciliationPresentationHost<Content: View>: View {
  let model: TripPlanningModel
  let reconciliationModel: CalendarReconciliationModel
  @Binding var isPresented: Bool
  @ViewBuilder let content: Content

  var body: some View {
    content
      .sheet(isPresented: $isPresented, onDismiss: {
        model.reloadCalendarTimeAuthority()
      }) {
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

/// Keeps the host's independent modal destinations out of the map/layout modifier
/// chain, which otherwise exceeds the Xcode 27 beta type checker's practical limit.
private struct TripPlanningPresentationHost<Content: View>: View {
  let model: TripPlanningModel
  @Binding var showingStartDay: Bool
  @ViewBuilder let content: Content

  var body: some View {
    @Bindable var model = model
    content
      .sheet(item: $model.destination.idea, id: \.id) { draft in
        IdeaFormView(draft: draft.draft)
      }
      .sheet(
        isPresented: Binding(
          get: { model.destination?.is(\.addIdeas) ?? false },
          set: { model.destination = $0 ? .addIdeas : nil }
        )
      ) {
        AddIdeasSheet(model: model)
      }
      .sheet(item: $model.destination.placeIdea, id: \.id) { target in
        PlaceIdeaSheet(model: model, target: target)
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
      .sheet(item: $model.destination.booking, id: \.id) { draft in
        BookingSheet(model: model, draft: draft)
      }
      .sheet(item: $model.destination.recommendationHandoff, id: \.id) { presentation in
        RecommendationHandoffSheet(model: model, session: presentation.session)
      }
      .sheet(isPresented: $showingStartDay) {
        StartDayPanel(model: model)
      }
  }
}

private struct AlternativeSourceSheet: View {
  let model: TripPlanningModel
  let target: AlternativeSourceTarget
  @Environment(\.dismiss) private var dismiss

  private var targetTitle: String {
    model.plan.scheduled.first { $0.id == target.targetStopID }?.content.title ?? "this stop"
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.plan.shortlist.isEmpty {
          ContentUnavailableView {
            Icon.shortlist.label("Nothing shortlisted yet")
          } description: {
            Text("Shortlist an idea first, then add it as an alternative to this stop.")
          }
        } else {
          List {
            ForEach(model.plan.shortlist) { source in
              Button {
                model.shortlistAlternativeSelected(source.id, for: target.targetStopID)
              } label: {
                alternativePickerRow(source, detail: source.idea?.kind?.label)
              }
            }
          }
        }
      }
      .navigationTitle("Alternative to \(targetTitle)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Custom Stop") {
            model.addCustomAlternativeButtonTapped(to: target.targetStopID)
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

private struct AlternativeSlotSheet: View {
  let model: TripPlanningModel
  let target: AlternativeSlotTarget
  @Environment(\.dismiss) private var dismiss

  private var sourceTitle: String {
    model.plan.shortlist.first { $0.id == target.sourceStopID }?.content.title ?? "this idea"
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.plan.scheduled.isEmpty {
          ContentUnavailableView {
            Icon.schedule.label("No itinerary slots yet")
          } description: {
            Text("Schedule a stop first, then this idea can become an alternative to it.")
          }
        } else {
          List {
            ForEach(model.plan.scheduled) { slot in
              Button {
                model.alternativeSlotSelected(slot.id, for: target.sourceStopID)
              } label: {
                alternativePickerRow(slot, detail: slot.entry.schedule.display)
              }
            }
          }
        }
      }
      .navigationTitle("Alternative to…")
      .navigationSubtitle(sourceTitle)
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

private func alternativePickerRow(_ stop: ResolvedStop, detail: String?) -> some View {
  HStack(spacing: 12) {
    Image(systemName: stop.idea?.kind?.systemImage ?? "mappin.and.ellipse")
      .foregroundStyle(.secondary)
      .frame(width: 24)
    VStack(alignment: .leading, spacing: 2) {
      Text(stop.content.title).foregroundStyle(.primary)
      if let detail {
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
      }
    }
    Spacer()
  }
}
