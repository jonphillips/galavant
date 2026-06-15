import GalavantSchema
import SwiftUI

/// The list-based second projection of the trip canvas (M3d) — the same shared
/// selection as the map, shown as a list. A segmented control swaps between the
/// **Itinerary** (the day timeline, focused to the day chip's lens) and **Ideas**
/// (the pulled pool: Shortlist / Scheduled / Considering). The context-sensitive
/// Add lives in its top bar; **Edit** lives in the trip's navigation toolbar.
///
/// This content is layout-agnostic: `TripPlanningView` hosts it as the persistent
/// bottom sheet on iPhone and as the right-hand column on iPad. The modal sheets
/// (edit form, Add-Ideas pool, Add Stop) are presented by the host so they stack
/// above either layout.
struct TripDetailContent: View {
  let model: TripPlanningModel

  var body: some View {
    @Bindable var model = model
    Group {
      switch model.sheetTab {
      case .itinerary:
        TripItineraryView(model: model, focusedDay: model.canvasSelectedDay)
      case .ideas:
        TripIdeasView(model: model)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        // The "toolbar" strip: just the context-sensitive Add (Edit lives in the
        // trip's nav bar).
        HStack {
          Spacer()
          addButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        // The Itinerary/Ideas switcher, pinned at the top of the content area so
        // it stays put while the list scrolls.
        Picker("View", selection: $model.sheetTab) {
          ForEach(TripPlanningModel.SheetTab.allCases) { tab in
            Text(tab.label).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
      }
    }
  }

  /// Add a pool idea on the Ideas tab; add an itinerary stop on the Itinerary tab.
  @ViewBuilder private var addButton: some View {
    switch model.sheetTab {
    case .ideas:
      Button { model.addIdeasButtonTapped() } label: { Icon.add.label("Add Ideas") }
    case .itinerary:
      Button { model.addStopButtonTapped() } label: { Icon.add.label("Add Stop") }
    }
  }
}
