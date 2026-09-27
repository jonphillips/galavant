import SwiftUI

/// "Add Ideas" for the trip's Ideas tab. It is pinned in the iPad column and
/// becomes the first scrolling list row on iPhone. The Itinerary has no tab-wide
/// add: each day's "+" sheet carries the day's note, custom stop, lodging, and
/// ideas, and the trip-shaping tools live in the trip's toolbar.
struct TripAddButton: View {
  let model: TripPlanningModel

  var body: some View {
    Button { model.addIdeasButtonTapped() } label: { Icon.add.label("Add Ideas") }
  }
}
