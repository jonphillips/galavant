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

  /// Add a pool idea on the Ideas tab. On the Itinerary tab a menu offers the two
  /// born-on-the-trip records: a freeform stop (ADR-0010) or lodging (ADR-0011) —
  /// a shortlisted idea is still added onto a day via that section's own "+".
  @ViewBuilder private var addButton: some View {
    switch model.sheetTab {
    case .ideas:
      Button { model.addIdeasButtonTapped() } label: { Icon.add.label("Add Ideas") }
    case .itinerary:
      Menu {
        Button { model.addCustomStopButtonTapped() } label: {
          Label("Custom Stop", systemImage: "mappin.and.ellipse")
        }
        Button { model.addLodgingButtonTapped() } label: {
          Icon.stay.label("Lodging")
        }
      } label: {
        Icon.add.label("Add")
      }
    }
  }
}
