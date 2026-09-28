import CoreLocation
import GalavantSchema
import SwiftUI

/// The Add-Ideas bottom sheet: the pool scoped by the trip's filter lens, each
/// row carrying the two one-tap state icons (`questionmark.bubble` = considering,
/// `star` = shortlist). Pulled up from the bottom over the Ideas tab.
struct AddIdeasSheet: View {
  let model: TripPlanningModel

  var body: some View {
    NavigationStack {
      List {
        ForEach(model.filteredPool) { idea in
          let status = model.status(for: idea)
          PlanningRow(idea: idea) {
            HStack(spacing: 18) {
              // Considering (thought bubble) and Shortlist (star) — one tap each
              // to set the state; the lit one shows where it sits. Tapping the
              // lit icon removes it from the trip.
              addToggle("questionmark.bubble", on: status == .considering) {
                model.tapConsidering(idea)
              }
              addToggle("star", on: status?.isOnShortlist == true) {
                model.tapShortlist(idea)
              }
            }
          }
        }
      }
      .overlay {
        if model.filteredPool.isEmpty {
          ContentUnavailableView {
            Icon.ideas.label("No ideas to pull")
          } description: {
            Text(model.isFiltering ? "No pool ideas match the filter." : "Capture ideas first on the Ideas screen.")
          }
        }
      }
      .navigationTitle("Add Ideas")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { filterMenu }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { model.destination = nil }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  /// One of the two quick-state icons; lit (filled + tinted) when the row is in
  /// that state.
  private func addToggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: on ? "\(symbol).fill" : symbol)
        .imageScale(.large)
        .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
    .buttonStyle(.borderless)
  }

  private var filterMenu: some View {
    @Bindable var model = model
    return Menu {
      Menu("Regions") {
        ForEach(model.sortedRegions) { region in
          Button {
            model.toggleRegion(region.id)
          } label: {
            checked(region.name, on: model.selectedRegionIDs.contains(region.id))
          }
        }
      }
      Menu("Kinds") {
        ForEach(IdeaKind.allCases, id: \.self) { kind in
          Button {
            model.toggleKind(kind)
          } label: {
            checked(kind.label, on: model.selectedKinds.contains(kind))
          }
        }
      }
      Menu("Tags") {
        ForEach(model.sortedTags) { tag in
          Button {
            model.toggleTag(tag.id)
          } label: {
            checked(tag.name, on: model.selectedTagIDs.contains(tag.id))
          }
        }
      }
      Toggle("Show visited", isOn: $model.includeVisited)
      if model.isFiltering {
        Button("Clear filters", role: .destructive) { model.clearFilters() }
      }
    } label: {
      Label(
        "Filter",
        systemImage: model.isFiltering
          ? Icon.filterActive.systemName
          : "line.3.horizontal.decrease.circle"
      )
    }
  }

  @ViewBuilder
  private func checked(_ title: String, on: Bool) -> some View {
    if on {
      Label(title, systemImage: Icon.checkmark.systemName)
    } else {
      Text(title)
    }
  }
}

/// The trip's actionable booking review. Its rows are the one-pass rollup passed
/// down by `TripPlanningView`; it never resolves booking status itself.
struct ToBookSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  let model: TripPlanningModel
  let rollup: TripBookingRollup
  @State private var showsBooked = false

  var body: some View {
    NavigationStack {
      List {
        if !rollup.toBook.isEmpty {
          Section("To Book") {
            ForEach(rollup.toBook, id: \.row) { item in
              toBookRow(item)
            }
          }
        }

        if !rollup.decide.isEmpty {
          Section("Decide") {
            ForEach(rollup.decide, id: \.row) { item in
              decideRow(item)
            }
          }
        }

        if !rollup.booked.isEmpty {
          Section {
            DisclosureGroup("Booked", isExpanded: $showsBooked) {
              ForEach(rollup.booked, id: \.row) { item in
                bookedRow(item)
              }
            }
          }
        }
      }
      .navigationTitle("To Book")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func toBookRow(_ item: TripBookingItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      itemTitle(item)
      HStack {
        if let url = item.bookingURL.flatMap(URL.init(string:)) {
          Button("Book") { openURL(url) }
        }
        Button("Mark booked") {
          model.setBookingStatus(.booked, for: item.row)
        }
        .buttonStyle(.borderedProminent)
      }
      .font(.subheadline)
    }
    .padding(.vertical, 2)
  }

  private func decideRow(_ item: TripBookingItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      itemTitle(item)
      HStack {
        Button("To book") {
          model.setBookingStatus(.toBook, for: item.row)
        }
        .buttonStyle(.borderedProminent)
        Button("Not needed") {
          model.setBookingStatus(.notNeeded, for: item.row)
        }
        .buttonStyle(.bordered)
      }
      .font(.subheadline)
    }
    .padding(.vertical, 2)
  }

  private func bookedRow(_ item: TripBookingItem) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      itemTitle(item)
      if let confirmation = item.confirmationNumber,
        !confirmation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        LabeledContent("Confirmation") {
          Text(confirmation).textSelection(.enabled)
        }
        .font(.subheadline)
      }
    }
    .padding(.vertical, 2)
  }

  private func itemTitle(_ item: TripBookingItem) -> some View {
    Button {
      model.editBookingItem(item)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .foregroundStyle(.primary)
        Text(timing(for: item))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
  }

  private func timing(for item: TripBookingItem) -> String {
    let day = item.day.map { dayLabel($0, trip: model.trip) } ?? "To Be Scheduled"
    guard let time = item.time else { return day }
    return "\(day) · \(time)"
  }
}

struct AlternativeAddMenu: View {
  let model: TripPlanningModel
  let targetStopID: TripIdea.ID

  var body: some View {
    Menu {
      Button("From Shortlist…", systemImage: Icon.shortlist.systemName) {
        model.addAlternativeButtonTapped(to: targetStopID)
      }
      Button("Custom Stop…", systemImage: Icon.addInline.systemName) {
        model.addCustomAlternativeButtonTapped(to: targetStopID)
      }
    } label: {
      Label("Add Alternative", systemImage: Icon.addInline.systemName)
    }
  }
}
