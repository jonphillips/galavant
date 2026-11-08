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
    let guide = model.guide
    let headerThumbnails = model.headerThumbnailByIdea
    let plannerNames = Dictionary(model.planners.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    return VStack(spacing: 0) {
      header(guide: guide)
      if horizontalSizeClass == .regular {
        IdeaMapSplitView(
          ideaID: model.dossierID,
          onBack: { model.closeDossier() },
          column: {
            guideList(guide, headerThumbnails: headerThumbnails, plannerNames: plannerNames)
          },
          map: { poolMap(guide) }
        )
      } else {
        Group {
          switch mode {
          case .list:
            guideList(guide, headerThumbnails: headerThumbnails, plannerNames: plannerNames)
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
        .navigationDestination(item: $model.destination.dossier) { ideaID in
          IdeaDetailView(ideaID: ideaID, canEdit: true)
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
      ContentUnavailableView("Nothing in \(model.shelf.label)", systemImage: Icon.ideas.systemName,
        description: Text("\(notForMeCount) \(notForMeCount == 1 ? "place is" : "places are") on Not for Me."))
    } else if let guide {
      List {
        ForEach(guide.sections) { section in
          Section(section.title) {
            ForEach(section.cards) { card in
              Button {
                model.ideaTapped(card.idea)
                focusedIdeaID = card.idea.id
              } label: {
                cardView(
                  card,
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
        if card.emphasis == .notesFirst, let note = card.latestNote {
          noteText(note, lines: 2, plannerNames: plannerNames)
        }
        if let accolade = card.accolade {
          Text("\(accolade.sourceName) · \(accolade.nativeDisplay)")
            .font(.subheadline)
        }
        if card.emphasis == .accoladesFirst, let note = card.latestNote {
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
        model.ideaTapped(idea)
      },
      onSelectMapPlace: { place in await model.mapPlaceTapped(place) },
      visibleRegion: $visibleRegion
    )
  }
}
