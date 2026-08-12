import GalavantSchema
import SwiftUI

/// Places a shortlisted idea on a target day. Previously scheduled ideas are
/// kept in a separate section so choosing one means an additional visit rather
/// than moving its existing occurrence.
struct PlaceIdeaSheet: View {
  let model: TripPlanningModel
  let target: PlaceIdeaTarget
  @Environment(\.dismiss) private var dismiss
  @Environment(AppRouter.self) private var router

  private var sectionLabel: String {
    target.day.map { dayLabel($0, trip: model.trip) } ?? "To Be Scheduled"
  }

  private var dayRegion: MapRegion? { target.day.flatMap { model.dayRegion(forDay: $0) } }
  private var browseLabel: String { dayRegion.map { "Browse \($0.name) Ideas" } ?? "Browse Ideas" }

  var body: some View {
    NavigationStack {
      Group {
        if model.plan.shortlist.isEmpty && (target.day == nil || model.plan.scheduled.isEmpty) {
          ContentUnavailableView {
            Icon.shortlist.label("Nothing shortlisted yet")
          } description: {
            Text("Browse the pool to find ideas for this day, then shortlist them to drop here.")
          } actions: {
            Button(action: browse) { Label(browseLabel, systemImage: Icon.map.systemName) }
              .buttonStyle(.borderedProminent)
          }
        } else {
          List {
            if !model.plan.shortlist.isEmpty {
              Section("Shortlist") {
                ForEach(model.plan.shortlist) { ideaButton($0, isRepeat: false) }
              }
            }
            if target.day != nil, !model.plan.scheduled.isEmpty {
              Section("Already Scheduled") {
                ForEach(model.plan.scheduled) { ideaButton($0, isRepeat: true) }
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
