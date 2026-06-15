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
  @State private var model: TripPlanningModel
  @State private var showDetailSheet = false
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

  init(trip: Trip) {
    _model = State(initialValue: TripPlanningModel(tripID: trip.id))
  }

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
      .navigationTitle(model.trip?.name ?? "Trip")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Edit") { model.editButtonTapped() }
        }
      }
      .task {
        model.pickInitialSheetTabIfNeeded()
        model.seedLensIfNeeded()
        // Present the persistent sheet on appear (compact only) — `.constant(true)`
        // is unreliable on a NavigationStack push.
        if !usesColumn { showDetailSheet = true }
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
      .sheet(
        isPresented: Binding(
          get: { model.destination?.is(\.scheduleStop) ?? false },
          set: { model.destination = $0 ? .scheduleStop : nil }
        )
      ) {
        ScheduleStopSheet(model: model)
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
      TripDetailContent(model: model)
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
        TripDetailContent(model: model)
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
