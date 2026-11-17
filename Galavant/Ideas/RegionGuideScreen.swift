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

  let scope: RegionGuideScope
  var onClose: (() -> Void)? = nil

  enum Mode: String, CaseIterable {
    case list, map
    var systemImage: String { self == .list ? "list.bullet" : "map" }
  }

  var body: some View {
    let tripLens = model.tripLens
    let openChoiceRanks = tripLens.map { model.openChoiceRanks(for: $0) } ?? [:]
    let sourceGuide = model.guide
    let availableLists = tripLens.map { model.availableLists(for: $0, guide: sourceGuide) } ?? []
    let selectedListRanks = model.selectedListRanks
    let focusedSlot = tripLens.flatMap { model.focusedSlot(in: $0, guide: sourceGuide) }
    let guide = model.visibleGuide(sourceGuide, focusedSlot: focusedSlot)
    let mapGuide = model.mapGuide(sourceGuide, focusedSlot: focusedSlot)
    let slotRows = model.slotRows(
      for: sourceGuide?.sections.flatMap(\.cards).map(\.idea) ?? [],
      focusedSlot: focusedSlot,
      lens: tripLens
    )
    let headerThumbnails = model.headerThumbnailByIdea
    let plannerNames = Dictionary(model.planners.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    return VStack(spacing: 0) {
      header(guide: guide)
      if horizontalSizeClass == .regular {
        IdeaMapSplitView(
          ideaID: model.dossierID,
          tripRationale: model.tripRationale(for: model.dossierID, tripLens: tripLens),
          onClose: closeDossier,
          column: {
            guideList(guide, tripLens: tripLens, focusedSlot: focusedSlot, slotRows: slotRows,
              headerThumbnails: headerThumbnails, plannerNames: plannerNames, openChoiceRanks: openChoiceRanks,
              availableLists: availableLists, selectedListRanks: selectedListRanks)
          },
          map: { poolMap(mapGuide) },
          dossierAccessory: { dossierAccessory(ideaID: model.dossierID, tripLens: tripLens, focusedSlot: focusedSlot) }
        )
      } else {
        Group {
          switch mode {
          case .list:
            guideList(guide, tripLens: tripLens, focusedSlot: focusedSlot, slotRows: slotRows,
              headerThumbnails: headerThumbnails, plannerNames: plannerNames, openChoiceRanks: openChoiceRanks,
              availableLists: availableLists, selectedListRanks: selectedListRanks)
          case .map: poolMap(mapGuide)
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
              tripRationale: model.tripRationale(for: ideaID, tripLens: tripLens),
              canEdit: true,
              chrome: .panel(onClose: closeDossier)
            )
            .id(ideaID)
            .safeAreaInset(edge: .bottom) { dossierAccessory(ideaID: ideaID, tripLens: tripLens, focusedSlot: focusedSlot) }
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
    .sensoryFeedback(.success, trigger: model.successfulAddCount)
  }

  @ViewBuilder private func dossierAccessory(
    ideaID: Idea.ID?, tripLens: GuideTripLens?, focusedSlot: GuideSlotFocus?
  ) -> some View {
    if let ideaID, let tripLens, let menu = model.slotMenu(for: ideaID, lens: tripLens) {
      if let focus = focusedSlot, case .open = focus.content,
         let row = menu.row(day: focus.day, meal: focus.meal) {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Button {
              guard let action = row.action else { return }
              _ = model.addToTrip(action, ideaID: ideaID)
            } label: {
              Text("Put in \(row.title)")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .disabled(row.action == nil)
            if row.action == nil {
              Text(row.detail).font(.caption).foregroundStyle(.secondary)
            }
          }
          addToTripMenu(menu, ideaID: ideaID, compact: true)
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
      } else {
        addToTripMenu(menu, ideaID: ideaID, compact: false)
          .buttonStyle(.borderedProminent)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(.bar)
      }
    }
  }

  private func addToTripMenu(_ menu: GuideSlotMenu, ideaID: Idea.ID, compact: Bool) -> some View {
    Menu {
      ForEach(Array(menu.sections.enumerated()), id: \.offset) { _, rows in
        Section {
          ForEach(rows) { row in
            Button {
              guard let action = row.action else { return }
              _ = model.addToTrip(action, ideaID: ideaID)
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
        .font(compact ? .body : .headline)
        .frame(maxWidth: compact ? nil : .infinity)
        .padding(.vertical, compact ? 0 : 12)
        .contentShape(Rectangle())
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
    focusedSlot: GuideSlotFocus?,
    slotRows: [Idea.ID: GuideSlotMenu.Row],
    headerThumbnails: [Idea.ID: Data],
    plannerNames: [Planner.ID: String],
    openChoiceRanks: [Idea.ID: ChatRank],
    availableLists: [TripIdea.RankedList],
    selectedListRanks: [Idea.ID: TripIdea.RankedList.Member]
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
    } else {
      List {
        if let tripLens {
          Section {
            RegionGuideTripLensView(lens: tripLens, model: model, horizontalSizeClass: horizontalSizeClass,
              onSelectSlot: { model.slotTapped(day: $0, meal: $1) })
              .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
          }
        }
        if let focusedSlot, let tripLens {
          Section {
            focusedSlotRows(focusedSlot, tripID: tripLens.trip.id)
          } header: {
            HStack {
              Text(focusedSlot.title)
              Spacer()
              Button { model.clearSlotFocus() } label: {
                Image(systemName: "xmark")
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Clear slot focus")
            }
          }
        }
        if focusedSlot?.isFilled != true, let guide, guide.sections.isEmpty {
          let notForMeCount = guide.counts[.notForMe, default: 0]
          ContentUnavailableView("Nothing in \(model.shelf.label)", systemImage: Icon.ideas.systemName,
            description: Text("\(notForMeCount) \(notForMeCount == 1 ? "place is" : "places are") on Not for Me."))
        } else if focusedSlot?.isFilled != true, let guide {
          ForEach(guide.sections) { section in
            RegionGuideCardSection(
              section: section,
              lists: section.id == guide.sections.first?.id ? availableLists : [],
              selectedListName: model.selectedList?.name,
              onSelectList: { model.selectedListName = $0 },
              row: { card in
                guideCard(card, tripLens: tripLens, slotRow: slotRows[card.idea.id],
                  thumbnails: headerThumbnails, plannerNames: plannerNames,
                  rank: model.selectedList == nil && tripLens != nil ? openChoiceRanks[card.idea.id] : nil,
                  listRank: selectedListRanks[card.idea.id])
              }
            )
          }
        }
      }
    }
  }

  private func guideCard(
    _ card: RegionGuide.Card,
    tripLens: GuideTripLens?,
    slotRow: GuideSlotMenu.Row?,
    thumbnails: [Idea.ID: Data],
    plannerNames: [Planner.ID: String],
    rank: ChatRank?,
    listRank: TripIdea.RankedList.Member?
  ) -> some View {
    return RegionGuideCardRow(
      card: card, headerThumbnail: thumbnails[card.idea.id], plannerNames: plannerNames,
      badge: tripLens?.badgeLabel(for: card.idea.id), rank: rank, listRank: listRank,
      isFocused: focusedIdeaID == card.idea.id,
      onTap: {
        focusedIdeaID = card.idea.id
        model.ideaTapped(card.idea)
      },
      putInTitle: slotRow?.action == nil ? nil : slotRow.map { "Put in \($0.title)" },
      onPutHere: slotRow?.action.map { action in
        { _ = model.addToTrip(action, ideaID: card.idea.id) }
      })
  }

  @ViewBuilder private func focusedSlotRows(_ focus: GuideSlotFocus, tripID: Trip.ID) -> some View {
    if case let .filled(stops) = focus.content {
      ForEach(stops) { stop in
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            if let ideaID = stop.ideaID {
              Button(stop.title) {
                focusedIdeaID = ideaID
                model.tripStopTapped(ideaID)
              }
                .buttonStyle(.plain)
            } else {
              Text(stop.title).italic()
            }
            if let distance = model.distanceFromStay(ideaID: stop.ideaID, tripID: tripID, day: focus.day) {
              Text("\(distance.distance.formatted(.measurement(width: .abbreviated, usage: .road))) from \(distance.hotelName)")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          if stop.isAlternative && stop.isActive { Text("Active").font(.caption).foregroundStyle(.secondary) }
          Spacer()
          if stop.isAlternative && !stop.isActive {
            Button("Make active") { model.setActive(stopID: stop.id) }
          }
          Button("Take out") { model.takeOut(stopID: stop.id) }
        }
      }
    }
  }

  private func poolMap(_ guide: RegionGuide?) -> some View {
    PoolMapView(
      ideas: guide?.sections.flatMap(\.cards).map(\.idea) ?? [],
      framingRegions: model.region.map { [$0] } ?? [],
      placeSelectionPolicy: horizontalSizeClass == .regular ? .exploreFirst(.popover) : .exploreFirst(.sheet),
      selectedIdeaID: focusedIdeaID,
      onSelect: { idea in
        focusedIdeaID = idea.id
        model.ideaTapped(idea)
      },
      onSelectMapPlace: { place in await model.mapPlaceTapped(place) },
      visibleRegion: $visibleRegion
    )
  }

  private func closeDossier() {
    focusedIdeaID = nil
    model.closeDossier()
  }
}

private struct RegionGuideCardSection<Row: View>: View {
  let section: RegionGuide.Section
  let lists: [TripIdea.RankedList]
  let selectedListName: String?
  let onSelectList: (String?) -> Void
  let row: (RegionGuide.Card) -> Row

  var body: some View {
    Section {
      ForEach(section.cards) { card in row(card) }
    } header: {
      RegionGuideListHeader(
        title: section.title, lists: lists,
        selectedListName: selectedListName, onSelectList: onSelectList)
    }
  }
}

private struct RegionGuideListHeader: View {
  let title: String
  let lists: [TripIdea.RankedList]
  let selectedListName: String?
  let onSelectList: (String?) -> Void

  var body: some View {
    HStack {
      Text(title)
      Spacer()
      if !lists.isEmpty {
        Menu {
          Button {
            onSelectList(nil)
          } label: {
            if selectedListName == nil {
              Label("All places", systemImage: "checkmark")
            } else {
              Text("All places")
            }
          }
          Divider()
          ForEach(lists) { list in
            Button {
              onSelectList(list.name)
            } label: {
              if selectedListName == list.name {
                Label("\(list.name) · \(list.members.count)", systemImage: "checkmark")
              } else {
                Text("\(list.name) · \(list.members.count)")
              }
            }
          }
        } label: {
          HStack(spacing: 4) {
            Text(selectedListName ?? "All places")
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
          }
        }
        .accessibilityLabel("Named list")
      }
    }
  }
}
