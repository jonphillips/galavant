import Dependencies
import GalavantSchema
import MapKit
import SQLiteData
import Sharing
import SwiftUI
import UIKit

@MainActor
@Observable
final class RegionGuideModel {
  @ObservationIgnored @FetchAll(Idea.all) var ideas
  @ObservationIgnored @FetchAll(IdeaEvaluation.all) var evaluations
  @ObservationIgnored @FetchAll(IdeaInterest.all) var interests
  @ObservationIgnored @FetchAll(Planner.all) var planners
  @ObservationIgnored @FetchAll(TasteNote.where { $0.ideaID.isNot(nil) }) var notes
  @ObservationIgnored @FetchAll(ImageAsset.where { $0.isHeader.eq(true) }
    .select { HeaderThumb.Columns(ideaID: $0.ideaID, thumbnail: $0.thumbnail) }) var headerThumbs
  @ObservationIgnored @Shared(.appStorage("lastRegionGuideID")) private var lastRegionID = ""

  var region: MapRegion?
  var category: GuideCategory = .dining
  var shelf: GuideShelf = .all
  private var initialScopeApplied = false

  @Selection
  struct HeaderThumb {
    let ideaID: Idea.ID
    let thumbnail: Data
  }

  var guide: RegionGuide? {
    guard let region else { return nil }
    return RegionGuide(
      region: region, category: category, shelf: shelf, ideas: ideas,
      evaluations: evaluations, interests: interests, planners: planners, notes: notes
    )
  }

  var headerThumbnailByIdea: [Idea.ID: Data] {
    Dictionary(headerThumbs.map { ($0.ideaID, $0.thumbnail) }, uniquingKeysWith: { first, _ in first })
  }

  func task(scope: RegionGuideScope, availableRegions: [MapRegion]) {
    guard !initialScopeApplied else { return }
    initialScopeApplied = true
    category = scope.category
    if let region = scope.region, availableRegions.contains(where: { $0.id == region.id }) {
      selectRegion(region)
    } else if let id = UUID(uuidString: lastRegionID),
      let region = availableRegions.first(where: { $0.id == id }) {
      selectRegion(region)
    }
  }

  func selectRegion(_ region: MapRegion?) {
    self.region = region
    $lastRegionID.withLock { $0 = region?.id.uuidString ?? "" }
  }
}

struct RegionGuideScreen: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var model = RegionGuideModel()
  @State private var mode: Mode = .list
  @State private var visibleRegion: MKCoordinateRegion?
  @State private var focusedIdeaID: Idea.ID?

  let scope: RegionGuideScope
  let ideasModel: IdeasListModel
  var onClose: (() -> Void)? = nil

  enum Mode: String, CaseIterable {
    case list, map
    var systemImage: String { self == .list ? "list.bullet" : "map" }
  }

  var body: some View {
    let guide = model.guide
    let category = model.category
    let headerThumbnails = model.headerThumbnailByIdea
    let plannerNames = Dictionary(model.planners.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    return VStack(spacing: 0) {
      header(guide: guide)
      if horizontalSizeClass == .regular {
        HStack(spacing: 0) {
          if case let .dossier(ideaID) = ideasModel.destination {
            IdeaDetailView(
              ideaID: ideaID,
              canEdit: true,
              onBack: { ideasModel.closeDossier() }
            )
            .frame(maxWidth: 440)
          } else {
            guideList(
              guide, category: category, headerThumbnails: headerThumbnails, plannerNames: plannerNames)
              .frame(maxWidth: 440)
          }
          Divider()
          poolMap(guide)
        }
      } else {
        Group {
          switch mode {
          case .list:
            guideList(
              guide, category: category, headerThumbnails: headerThumbnails, plannerNames: plannerNames)
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
      }
    }
    .navigationTitle("Region Guide")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if horizontalSizeClass == .regular, let onClose {
        ToolbarItem(placement: .topBarLeading) {
          Button("Back", systemImage: "chevron.left", action: onClose)
        }
      }
    }
    .task { model.task(scope: scope, availableRegions: ideasModel.sortedRegions) }
  }

  private func header(guide: RegionGuide?) -> some View {
    VStack(spacing: 10) {
      HStack {
        Menu {
          ForEach(ideasModel.sortedRegions) { region in
            Button(region.name) { model.selectRegion(region) }
          }
        } label: {
          Label(model.region?.name ?? "Choose a Region", systemImage: Icon.map.systemName)
            .lineLimit(1)
        }
        .disabled(ideasModel.sortedRegions.isEmpty)
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
    category: GuideCategory,
    headerThumbnails: [Idea.ID: Data],
    plannerNames: [Planner.ID: String]
  ) -> some View {
    if ideasModel.sortedRegions.isEmpty {
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
      ContentUnavailableView(
        "Nothing in \(model.shelf.label)",
        systemImage: Icon.ideas.systemName,
        description: Text("\(guide.counts[.notForMe, default: 0]) places are on Not for Me.")
      )
    } else if let guide {
      List {
        ForEach(guide.sections) { section in
          Section(section.title) {
            ForEach(section.cards) { card in
              Button {
                focusedIdeaID = card.idea.id
                ideasModel.ideaTapped(card.idea)
              } label: {
                cardView(
                  card, category: category,
                  headerThumbnail: headerThumbnails[card.idea.id], plannerNames: plannerNames)
              }
              .buttonStyle(.plain)
              .listRowBackground(focusedIdeaID == card.idea.id ? Color.accentColor.opacity(0.15) : nil)
            }
          }
        }
      }
    }
  }

  private func cardView(
    _ card: RegionGuide.Card,
    category: GuideCategory,
    headerThumbnail: Data?,
    plannerNames: [Planner.ID: String]
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      if let headerThumbnail, let image = UIImage(data: headerThumbnail) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 70, height: 70)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(card.idea.name).font(.headline)
        let address = card.idea.address.flatMap { $0.isEmpty ? nil : $0 }
        if let locality = address ?? card.idea.regionName, !locality.isEmpty {
          Text(locality).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        if category == .hotels, let note = card.latestNote {
          noteText(note, lines: 2, plannerNames: plannerNames)
        }
        if let accolade = card.accolade {
          Text("\(accolade.sourceName) · \(accolade.nativeDisplay)")
            .font(.subheadline)
        }
        if category == .dining, let note = card.latestNote {
          noteText(note, lines: 1, plannerNames: plannerNames)
        }
        HStack(spacing: 10) {
          ForEach(card.interests, id: \.planner.id) { entry in
            Text("\(entry.planner.displayName): \(entry.level?.label ?? "Not rated")")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if card.idea.visited {
            Label("Visited", systemImage: Icon.checkmark.systemName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private func noteText(
    _ note: TasteNote, lines: Int, plannerNames: [Planner.ID: String]
  ) -> some View {
    let who = note.plannerID.flatMap { plannerNames[$0] } ?? "Both of us"
    let firstLine = note.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? note.body
    return Text("\(firstLine) · \(who)")
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .lineLimit(lines)
  }

  private func poolMap(_ guide: RegionGuide?) -> some View {
    PoolMapView(
      ideas: guide?.sections.flatMap(\.cards).map(\.idea) ?? [],
      framingRegions: model.region.map { [$0] } ?? [],
      placeSelectionPolicy: horizontalSizeClass == .regular ? .exploreFirst(.popover) : .exploreFirst(.sheet),
      selectedIdeaID: horizontalSizeClass == .regular ? focusedIdeaID : nil,
      onSelect: { idea in
        focusedIdeaID = idea.id
        ideasModel.ideaTapped(idea)
      },
      onSelectMapPlace: { place in
        await ideasModel.mapPlaceTapped(place, searchRegions: model.region.map { [$0] } ?? [])
      },
      visibleRegion: $visibleRegion
    )
  }
}
