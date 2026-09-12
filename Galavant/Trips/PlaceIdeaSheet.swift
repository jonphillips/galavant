import GalavantSchema
import SwiftUI

/// Places a shortlisted idea on a target day. Previously scheduled ideas are
/// kept in a separate section so choosing one means an additional visit rather
/// than moving its existing occurrence.
///
/// When the target day carries a region (ADR-0012), the picker is scoped to ideas
/// inside it (dogfood #5) — you only see what belongs there. "Show all" is the
/// escape hatch for a shortlisted idea that lives outside the region, or one with
/// no coordinate to place.
struct PlaceIdeaSheet: View {
  let model: TripPlanningModel
  let target: PlaceIdeaTarget
  @Environment(\.dismiss) private var dismiss
  @Environment(AppRouter.self) private var router
  /// Lift the region scope for this visit — surfaces shortlisted ideas outside the
  /// day's region (and unlocated ones the containment check can't place).
  @State private var showAll = false

  private var sectionLabel: String {
    target.day.map { dayLabel($0, trip: model.trip) } ?? "To Be Scheduled"
  }

  private var dayRegion: MapRegion? { target.day.flatMap { model.dayRegion(forDay: $0) } }
  private var browseLabel: String { dayRegion.map { "Browse \($0.name) Ideas" } ?? "Browse Ideas" }

  /// True while a day region is actively narrowing the lists (not lifted via "Show all").
  private var isRegionScoped: Bool { dayRegion != nil && !showAll }

  private var shortlistStops: [ResolvedStop] {
    isRegionScoped
      ? model.plan.stops(model.plan.shortlist, inRegionForDay: target.day)
      : model.plan.shortlist
  }

  private var scheduledStops: [ResolvedStop] {
    isRegionScoped
      ? model.plan.stops(model.plan.scheduled, inRegionForDay: target.day)
      : model.plan.scheduled
  }

  /// Shortlisted ideas hidden by the region scope — drives the "show all" affordance.
  private var hiddenByRegion: Int {
    guard isRegionScoped else { return 0 }
    return model.plan.shortlist.count - shortlistStops.count
  }

  var body: some View {
    NavigationStack {
      Group {
        if shortlistStops.isEmpty && (target.day == nil || scheduledStops.isEmpty) {
          emptyState
        } else {
          List {
            if !shortlistStops.isEmpty {
              Section {
                ForEach(shortlistStops) { ideaButton($0, isRepeat: false) }
              } header: {
                Text("Shortlist")
              } footer: {
                if let region = dayRegion, isRegionScoped {
                  showAllFooter(region: region)
                }
              }
            }
            if target.day != nil, !scheduledStops.isEmpty {
              Section {
                ForEach(scheduledStops) { ideaButton($0, isRepeat: true) }
              } header: {
                Text("Already Scheduled")
              } footer: {
                Text("Choosing one creates another visit without changing the existing one.")
              }
            }
          }
        }
      }
      .navigationTitle("Add to \(sectionLabel)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
          Button(action: browse) { Label(browseLabel, systemImage: Icon.map.systemName) }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  /// Empty either because nothing is shortlisted, or because the day's region hid
  /// every shortlisted idea — the second case offers "show all" alongside Browse.
  @ViewBuilder
  private var emptyState: some View {
    if let region = dayRegion, isRegionScoped, !model.plan.shortlist.isEmpty {
      ContentUnavailableView {
        Icon.shortlist.label("Nothing shortlisted in \(region.name)")
      } description: {
        Text("Your shortlist has ideas, but none fall in this day's region. Browse \(region.name), or show the whole shortlist.")
      } actions: {
        Button(action: browse) { Label(browseLabel, systemImage: Icon.map.systemName) }
          .buttonStyle(.borderedProminent)
        Button("Show all shortlisted ideas") { showAll = true }
      }
    } else {
      ContentUnavailableView {
        Icon.shortlist.label("Nothing shortlisted yet")
      } description: {
        Text("Browse the pool to find ideas for this day, then shortlist them to drop here.")
      } actions: {
        Button(action: browse) { Label(browseLabel, systemImage: Icon.map.systemName) }
          .buttonStyle(.borderedProminent)
      }
    }
  }

  @ViewBuilder
  private func showAllFooter(region: MapRegion) -> some View {
    if hiddenByRegion > 0 {
      Button {
        showAll = true
      } label: {
        Text("Showing \(region.name) ideas · Show all \(model.plan.shortlist.count)")
      }
      .font(.footnote)
    } else {
      Text("Showing ideas in \(region.name).")
    }
  }

  private func browse() {
    dismiss()
    router.browseIdeas(forTrip: model.tripID, regionID: dayRegion?.id)
  }

  private func ideaButton(_ resolved: ResolvedStop, isRepeat: Bool) -> some View {
    Button {
      if isRepeat { model.placeRepeat(of: resolved, on: target.day) }
      else { model.placeIdea(resolved.id, on: target.day) }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: resolved.content.idea?.kind?.systemImage ?? "mappin.and.ellipse")
          .foregroundStyle(.secondary)
          .frame(width: 24)
        Text(resolved.content.title).foregroundStyle(.primary)
        Spacer()
      }
    }
  }
}
