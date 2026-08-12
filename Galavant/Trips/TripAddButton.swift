import SwiftUI

/// The context-sensitive entry point for adding to the current trip tab. It is
/// pinned in the iPad column and becomes the first scrolling list row on iPhone.
struct TripAddButton: View {
  let model: TripPlanningModel
  let tab: TripPlanningModel.SheetTab

  var body: some View {
    switch tab {
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
