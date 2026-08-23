import Foundation
import GalavantSchema
import MapKit
import SwiftUI

/// What the map is currently focused on. Tapping a day or a stay elsewhere on
/// the surface flies the (otherwise fixed) map to the related pins; tapping the
/// same element again clears the focus back to the whole trip.
enum JourneySelection: Equatable {
  case day(Int)
  case stay(TripStay.ID)
}

/// The iPad anticipation surface for one trip. Journey is read-only and regular
/// width by design; Today is the compact/iPhone execution surface.
struct JourneyView: View {
  let planningModel: TripPlanningModel

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dismiss) private var dismiss
  @State private var model = JourneyModel()
  @State private var projection: JourneyProjection?
  @State private var renderedPlan: TripPlan?
  @State private var selection: JourneySelection?

  /// The breathing room between the header, stay rail, and the map/day area.
  /// Keeping one value for both boundaries makes the vertical rhythm symmetric.
  private static let sectionSpacing: CGFloat = 16

  private struct ProjectionInput: Equatable {
    var plan: TripPlan
    var tripStartDate: Date?
    var travelTimes: [LegKey: [TransportMode: TravelTime]]
  }

  private var projectionInput: ProjectionInput {
    ProjectionInput(
      plan: planningModel.plan,
      tripStartDate: planningModel.trip?.startDate,
      travelTimes: planningModel.travelTimes)
  }

  var body: some View {
    Group {
      if horizontalSizeClass == .regular {
        if let projection, let renderedPlan {
          journey(projection, plan: renderedPlan)
        } else if projectionInput.tripStartDate != nil {
          ProgressView("Preparing Journey…")
        } else {
          ContentUnavailableView(
            "Journey is not available",
            systemImage: "calendar.badge.clock",
            description: Text("Set this trip’s start date before opening Journey."))
        }
      } else {
        ContentUnavailableView(
          "Journey is an iPad view",
          systemImage: "ipad",
          description: Text("Use Today on iPhone for the on-the-go trip view."))
      }
    }
    // The trip name is the in-content hero (`JourneySummaryHeader`), so the nav
    // bar carries no title of its own — an inline empty title leaves just Done.
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Done") { dismiss() }
      }
    }
    .task(id: projectionInput) {
      let input = projectionInput
      guard let tripStartDate = input.tripStartDate else {
        projection = nil
        renderedPlan = nil
        await model.loadWeather(for: nil)
        return
      }
      let resolved = JourneyProjection.resolve(
        from: input.plan,
        tripStartDate: tripStartDate,
        travelTimes: input.travelTimes)
      guard !Task.isCancelled else { return }
      projection = resolved
      renderedPlan = input.plan
      await model.loadWeather(for: resolved)
    }
  }

  /// The screen is a fixed frame: the header and stay rail pin to the top, the
  /// day spine scrolls on the left, and the map holds still on the right so
  /// scrolling never drags it away to geography the trip never touches.
  private func journey(_ projection: JourneyProjection, plan: TripPlan) -> some View {
    VStack(alignment: .leading, spacing: Self.sectionSpacing) {
      HStack(alignment: .top, spacing: 16) {
        JourneySummaryHeader(trip: planningModel.trip, summary: projection.summary)
        Spacer(minLength: 16)
        // The header row's right side — empty until now — carries the image band;
        // the map keeps its own full-height column below, untouched.
        JourneyImagePanel(
          projection: projection, plan: plan, model: model, selection: selection)
          .frame(maxWidth: 520, alignment: .trailing)
      }
      .padding(.horizontal)
      .padding(.top, 8)
      JourneyStayRail(projection: projection, selection: $selection)

      HStack(alignment: .top, spacing: 16) {
        ScrollViewReader { proxy in
          ScrollView {
            JourneyDaySpine(projection: projection, model: model, selection: $selection)
              .padding(.horizontal)
              .padding(.bottom, 24)
          }
          // Tapping a lodging capsule jumps the day spine to that stay's first
          // day, so the rail and the spine stay in sync as you browse stays.
          .onChange(of: selection) { _, newValue in
            guard case .stay(let id) = newValue,
              let band = projection.stayBands.first(where: { $0.id == id })
            else { return }
            withAnimation(.easeInOut) {
              proxy.scrollTo(band.nights.lowerBound, anchor: .top)
            }
          }
        }
        JourneyMap(projection: projection, plan: plan, selection: selection)
          .frame(minWidth: 300, idealWidth: 400, maxWidth: 480)
          .frame(maxHeight: .infinity)
          .padding(.trailing)
          .padding(.bottom)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(.systemGroupedBackground))
    .safeAreaInset(edge: .bottom) {
      if let attribution = model.attribution {
        HStack {
          Spacer()
          WeatherAttributionLink(attribution: attribution)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
      }
    }
  }
}
