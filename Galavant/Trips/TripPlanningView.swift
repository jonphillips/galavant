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
/// Edit lives in the trip's navigation toolbar; the context Add lives on the
/// sheet/column; the modal sheets are presented from here so they stack over
/// either layout.
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
  @State private var showingHeaderPicker = false
  /// The "Sync to Calendar" action (BACKLOG "Export itinerary to Apple Calendar
  /// / iCal") — a fresh model per view, not cached on the router: the export
  /// pass is a one-shot fire-and-forget, unlike the planning model's
  /// persistent in-trip state.
  @State private var calendarExportModel = CalendarExportModel()
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
    layout
      // Inspector nested *below* the toolbar host: an `.inspector` applied outside a
      // toolbar-bearing view swallows its `.toolbar` on iPad (docs/KNOWN-ISSUES.md).
      .chatPanel(isPresented: $showingChat, context: .trip(model.plan))
      .navigationTitle(model.trip?.name ?? "Trip")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Edit") { model.editButtonTapped() }
        }
        // Choose/change the trip's "romance" header photo (ADR-0032).
        ToolbarItem {
          Button {
            showingHeaderPicker = true
          } label: {
            Icon.headerImage.label("Header Photo")
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
        // Start-day check: which start weekdays keep every keyed stop open (ADR-0029).
        // Shown only once some stop carries structured hours to constrain the start.
        if !model.startDaySolverStops.isEmpty {
          ToolbarItem {
            Button {
              showingStartDay = true
            } label: {
              Label("Start Day", systemImage: "calendar.badge.clock")
            }
          }
        }
        calendarExportToolbarItem
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
        guard id != nil else { return }
        // A selected stop lives on the Itinerary, so surface that tab — otherwise
        // tapping a pin while on Ideas would scroll a list it isn't in.
        model.sheetTab = .itinerary
        // On iPhone, nudge the sheet up from its peek so the timeline shows.
        if !usesColumn, sheetDetent == Self.peek { sheetDetent = .medium }
      }
      .onChange(of: model.detailIdeaID) { _, id in
        // Drilling into a stop's detail pushes within the sheet — raise it off the
        // peek so the pushed panel has room to read (iPhone only).
        guard id != nil, !usesColumn, sheetDetent == Self.peek else { return }
        sheetDetent = .medium
      }
      // Modal sheets, hoisted to the host so they stack above either layout.
      .sheet(item: $model.destination.edit, id: \.id) { draft in
        TripFormView(draft: draft)
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
      .sheet(item: $model.destination.stay, id: \.id) { draft in
        StaySheet(model: model, draft: draft)
      }
      .sheet(item: $model.destination.stopTime, id: \.id) { draft in
        StopTimeSheet(model: model, draft: draft)
      }
      .sheet(item: $model.destination.booking, id: \.id) { draft in
        BookingSheet(model: model, draft: draft)
      }
      .sheet(isPresented: $showingStartDay) {
        StartDayPanel(model: model)
      }
      .sheet(isPresented: $showingHeaderPicker) {
        if let trip = model.trip {
          TripHeaderPickerSheet(
            tripID: trip.id,
            tripName: trip.name,
            primaryRegionName: model.tripRegions.first?.name,
            hasHeader: trip.headerImage != nil
          )
        }
      }
      // Result of the "Sync to Calendar" action — a single OK dismisses either
      // a success summary or a failure message (e.g. access denied).
      .alert(
        "Calendar",
        isPresented: Binding(
          get: { calendarExportModel.isShowingResult },
          set: { if !$0 { calendarExportModel.dismissResult() } }
        )
      ) {
        Button("OK") { calendarExportModel.dismissResult() }
      } message: {
        Text(calendarExportModel.resultMessage)
      }
  }

  /// Export the itinerary to a dedicated device-local calendar (BACKLOG
  /// "Export itinerary to Apple Calendar / iCal") — only once the trip is
  /// dated (day-relative-only trips have no calendar date to export to).
  /// Factored out of the main `.toolbar` builder: inlining this conditional
  /// item there blew past the type-checker's time budget.
  @ToolbarContentBuilder private var calendarExportToolbarItem: some ToolbarContent {
    if let trip = model.trip, trip.certainty.stage == .dated {
      ToolbarItem {
        Button {
          Task { await calendarExportModel.exportButtonTapped(trip: trip, plan: model.plan) }
        } label: {
          Icon.calendar.label("Sync to Calendar")
        }
        .disabled(calendarExportModel.state == .exporting)
      }
    }
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
      TripDetailContent(model: model, onChooseHeader: { showingHeaderPicker = true })
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
        TripDetailContent(model: model, onChooseHeader: { showingHeaderPicker = true })
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
