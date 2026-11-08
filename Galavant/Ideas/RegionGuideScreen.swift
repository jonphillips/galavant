import MapKit
import GalavantSchema
import SwiftUI
import UIKit

struct RegionGuideScreen: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var model = RegionGuideModel()
  @State private var mode: Mode = .list
  @State private var visibleRegion: MKCoordinateRegion?
  @State private var focusedIdeaID: Idea.ID?
  @State private var addedIdeaID: Idea.ID?
  @State private var focusedSlot: FocusedMealSlot?

  let scope: RegionGuideScope
  var onClose: (() -> Void)? = nil

  enum Mode: String, CaseIterable {
    case list, map
    var systemImage: String { self == .list ? "list.bullet" : "map" }
  }

  private struct FocusedMealSlot: Equatable {
    var day: Int
    var meal: Meal
  }

  var body: some View {
    let tripLens = model.tripLens
    let guide = filteredGuide(model.guide, lens: tripLens)
    let headerThumbnails = model.headerThumbnailByIdea
    let plannerNames = Dictionary(model.planners.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    return VStack(spacing: 0) {
      header(guide: guide)
      if horizontalSizeClass == .regular {
        IdeaMapSplitView(
          ideaID: model.dossierID,
          onClose: { model.closeDossier() },
          column: {
            guideList(guide, tripLens: tripLens, headerThumbnails: headerThumbnails, plannerNames: plannerNames)
          },
          map: { poolMap(guide) },
          dossierAccessory: { dossierAccessory(ideaID: model.dossierID) }
        )
      } else {
        Group {
          switch mode {
          case .list:
            guideList(guide, tripLens: tripLens, headerThumbnails: headerThumbnails, plannerNames: plannerNames)
          case .map: poolMap(guide)
          }
        }
        .toolbar {
          ToolbarItem(placement: .principal) {
            Picker("View", selection: $mode) {
              ForEach(Mode.allCases, id: \.self) { mode in
                Image(systemName: mode.systemImage).tag(mode)
              }
            }
            .pickerStyle(.segmented)
          }
        }
        .sheet(isPresented: Binding($model.destination.dossier)) {
          if let ideaID = model.dossierID {
            IdeaDetailView(
              ideaID: ideaID,
              canEdit: true,
              chrome: .panel(onClose: { model.closeDossier() })
            )
            .id(ideaID)
            .safeAreaInset(edge: .bottom) { dossierAccessory(ideaID: ideaID) }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
          }
        }
      }
    }
    .navigationTitle("Region Guide")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $model.destination.form) { presentation in
      IdeaFormView(draft: presentation.draft, searchRegions: presentation.searchRegions)
    }
    .toolbar {
      if horizontalSizeClass == .regular, let onClose {
        ToolbarItem(placement: .topBarLeading) {
          Button("Back", systemImage: "chevron.left", action: onClose)
        }
      }
    }
    .task { model.task(scope: scope) }
    .sensoryFeedback(.success, trigger: addedIdeaID)
  }

  @ViewBuilder private func dossierAccessory(ideaID: Idea.ID?) -> some View {
    if let ideaID, let menu = model.slotMenu(for: ideaID) {
      Menu {
        ForEach(Array(menu.sections.enumerated()), id: \.offset) { _, rows in
          Section {
            ForEach(rows) { row in
              Button {
                guard let action = row.action else { return }
                if model.addToTrip(action, ideaID: ideaID) { addedIdeaID = ideaID }
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                  }
                  if row.isCurrent { Image(systemName: "checkmark") }
                }
              }
              .disabled(row.action == nil)
            }
          }
        }
      } label: {
        Label("Add to Trip", systemImage: "plus")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderedProminent)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.bar)
    }
  }

  private func header(guide: RegionGuide?) -> some View {
    VStack(spacing: 10) {
      HStack {
        Menu {
          ForEach(model.sortedRegions) { region in
            Button(region.name) { model.selectRegion(region) }
          }
        } label: {
          Label(model.region?.name ?? "Choose a Region", systemImage: Icon.map.systemName)
            .lineLimit(1)
        }
        .disabled(model.sortedRegions.isEmpty)
        Spacer()
        Picker("Category", selection: $model.category) {
          Text("Dining").tag(GuideCategory.dining)
          Text("Hotels").tag(GuideCategory.hotels)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 240)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(GuideShelf.allCases, id: \.self) { shelf in
            let count = guide?.counts[shelf] ?? 0
            Button {
              model.shelf = shelf
            } label: {
              Text("\(shelf.label) · \(count)")
                .font(.subheadline)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(model.shelf == shelf ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial)))
                .foregroundStyle(model.shelf == shelf ? Color.white : Color.primary)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.shelf == shelf ? .isSelected : [])
          }
        }
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
    .background(.bar)
  }

  @ViewBuilder private func guideList(
    _ guide: RegionGuide?,
    tripLens: GuideTripLens?,
    headerThumbnails: [Idea.ID: Data],
    plannerNames: [Planner.ID: String]
  ) -> some View {
    if model.sortedRegions.isEmpty {
      ContentUnavailableView(
        "No saved regions",
        systemImage: Icon.map.systemName,
        description: Text("Save a region from the Ideas map to see its guide.")
      )
    } else if model.region == nil {
      ContentUnavailableView(
        "Choose a region",
        systemImage: Icon.map.systemName,
        description: Text("Choose a saved region to see its places.")
      )
    } else if let guide, guide.sections.isEmpty {
      let notForMeCount = guide.counts[.notForMe, default: 0]
      VStack(spacing: 0) {
        if let tripLens {
          RegionGuideTripLensView(lens: tripLens, model: model, horizontalSizeClass: horizontalSizeClass,
            onSelectSlot: selectSlot(day:meal:)).padding(.horizontal)
        }
        ContentUnavailableView("Nothing in \(model.shelf.label)", systemImage: Icon.ideas.systemName,
          description: Text("\(notForMeCount) \(notForMeCount == 1 ? "place is" : "places are") on Not for Me."))
      }
    } else if let guide {
      List {
        if let tripLens {
          Section {
            RegionGuideTripLensView(lens: tripLens, model: model, horizontalSizeClass: horizontalSizeClass,
              onSelectSlot: selectSlot(day:meal:))
              .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
          }
        }
        if let focusedSlot, let tripLens {
          Section {
            focusedSlotRows(focusedSlot, lens: tripLens)
          } header: {
            HStack {
              Text(focusedSlotTitle(focusedSlot, lens: tripLens))
              Spacer()
              Button("Clear") { self.focusedSlot = nil }
            }
          }
        }
        ForEach(guide.sections) { section in
          Section(section.title) {
            ForEach(section.cards) { card in
              RegionGuideCardRow(
                card: card, headerThumbnail: headerThumbnails[card.idea.id], plannerNames: plannerNames,
                badge: tripLens?.badgeLabel(for: card.idea.id), isFocused: focusedIdeaID == card.idea.id,
                onTap: {
                  model.ideaTapped(card.idea)
                  focusedIdeaID = card.idea.id
                })
            }
          }
        }
      }
    }
  }

  private func filteredGuide(_ guide: RegionGuide?, lens: GuideTripLens?) -> RegionGuide? {
    guard let guide, let lens, let focusedSlot else { return guide }
    let ids = focusedIdeaIDs(focusedSlot, lens: lens, cards: guide.sections.flatMap(\.cards))
    let sections = guide.sections.compactMap { section -> RegionGuide.Section? in
      let cards = section.cards.filter { ids.contains($0.idea.id) }
      guard !cards.isEmpty else { return nil }
      return RegionGuide.Section(title: section.title, cards: cards, id: section.id)
    }
    return RegionGuide(sections: sections, counts: guide.counts)
  }

  private func focusedIdeaIDs(
    _ focus: FocusedMealSlot, lens: GuideTripLens, cards: [RegionGuide.Card]
  ) -> Set<Idea.ID> {
    guard case let .meals(days) = lens.body, let day = days.first(where: { $0.day == focus.day }) else { return [] }
    let cell = focus.meal == .lunch ? day.lunch : day.dinner
    switch cell {
    case .open:
      guard let weekday = day.weekday else { return Set(cards.map { $0.idea.id }) }
      return Set(cards.compactMap { card in
        card.idea.weeklyHours?.serves(focus.meal, on: weekday) == false ? nil : card.idea.id
      })
    case .filled:
      return Set(focusedEntries(focus, lens: lens).compactMap(\.ideaID))
    }
  }

  private func focusedEntries(_ focus: FocusedMealSlot, lens: GuideTripLens) -> [TripIdea] {
    guard case let .meals(days) = lens.body, let day = days.first(where: { $0.day == focus.day }) else { return [] }
    let cell = focus.meal == .lunch ? day.lunch : day.dinner
    guard case let .filled(stops) = cell, let first = stops.first,
      let entry = model.tripIdeas.first(where: { $0.id == first.id }) else { return [] }
    let entries = model.tripIdeas.filter { $0.tripID == lens.trip.id }
    guard let groupID = entry.alternativeGroupID else { return [entry] }
    return TripIdea.canonicalAlternativeOrder(entries.filter { $0.alternativeGroupID == groupID })
  }

  @ViewBuilder private func focusedSlotRows(_ focus: FocusedMealSlot, lens: GuideTripLens) -> some View {
    let entries = focusedEntries(focus, lens: lens)
    ForEach(entries) { entry in
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(entry.ideaID.flatMap { id in model.ideas.first { $0.id == id }?.name } ?? entry.inlineTitle ?? "Place")
          if let distance = model.distanceFromStay(entry: entry, day: focus.day) {
            Text(distance).font(.caption).foregroundStyle(.secondary)
          }
        }
        if entry.isActive && entry.alternativeGroupID != nil { Text("Active").font(.caption).foregroundStyle(.secondary) }
        Spacer()
        if entry.alternativeGroupID != nil && !entry.isActive {
          Button("Make active") { model.setActive(stopID: entry.id) }
        }
        Button("Take out") { model.takeOut(stopID: entry.id) }
      }
    }
  }

  private func focusedSlotTitle(_ focus: FocusedMealSlot, lens: GuideTripLens) -> String {
    let weekday: Weekday? = {
      guard case let .meals(days) = lens.body else { return nil }
      return days.first(where: { $0.day == focus.day })?.weekday
    }()
    let day = weekday?.shortLabel ?? "Day \(focus.day)"
    let stops = focusedIdeaIDs(focus, lens: lens, cards: []).count
    return stops == 0 ? "\(day) \(focus.meal.label.lowercased()) is open" : "Showing options for \(day) \(focus.meal.label.lowercased())"
  }

  private func selectSlot(day: Int, meal: Meal) {
    let selection = FocusedMealSlot(day: day, meal: meal)
    focusedSlot = focusedSlot == selection ? nil : selection
  }

  private func poolMap(_ guide: RegionGuide?) -> some View {
    PoolMapView(
      ideas: guide?.sections.flatMap(\.cards).map(\.idea) ?? [],
      framingRegions: model.region.map { [$0] } ?? [],
      placeSelectionPolicy: horizontalSizeClass == .regular ? .exploreFirst(.popover) : .exploreFirst(.sheet),
      selectedIdeaID: horizontalSizeClass == .regular ? focusedIdeaID : nil,
      onSelect: { idea in
        focusedIdeaID = idea.id
        model.ideaTapped(idea)
      },
      onSelectMapPlace: { place in await model.mapPlaceTapped(place) },
      visibleRegion: $visibleRegion
    )
  }
}
