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
    let tripLens = model.tripLens
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
          map: { poolMap(guide) }
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
        if let tripLens { tripLensView(tripLens).padding(.horizontal) }
        ContentUnavailableView("Nothing in \(model.shelf.label)", systemImage: Icon.ideas.systemName,
          description: Text("\(notForMeCount) \(notForMeCount == 1 ? "place is" : "places are") on Not for Me."))
      }
    } else if let guide {
      List {
        if let tripLens {
          Section {
            tripLensView(tripLens)
              .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
          }
        }
        ForEach(guide.sections) { section in
          Section(section.title) {
            ForEach(section.cards) { card in
              Button {
                model.ideaTapped(card.idea)
                focusedIdeaID = card.idea.id
              } label: {
                VStack(alignment: .leading, spacing: 6) {
                  cardView(card, headerThumbnail: headerThumbnails[card.idea.id], plannerNames: plannerNames)
                  if let tripLens, let badge = tripLens.badges[card.idea.id],
                     let trip = model.trips.first(where: { $0.id == tripLens.trip.id }) {
                    Text(badge.label(trip: trip, calendar: .current))
                      .font(.caption2.weight(.medium))
                      .padding(.horizontal, 7).padding(.vertical, 3)
                      .background(.thinMaterial, in: Capsule())
                  }
                }
              }
              .buttonStyle(.plain)
              .listRowBackground(focusedIdeaID == card.idea.id ? Color.accentColor.opacity(0.15) : nil)
            }
          }
        }
      }
    }
  }

  @ViewBuilder private func tripLensView(_ lens: GuideTripLens) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Menu {
          ForEach([lens.trip] + lens.otherTrips) { trip in
            Button(trip.name) { model.tripSelected(trip.id) }
          }
        } label: {
          Label(lens.trip.name, systemImage: "airplane")
            .font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        Spacer()
        Text(lensHeading(lens))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Button { model.lensFoldButtonTapped() } label: {
          Image(systemName: model.lensFolded ? "chevron.down" : "chevron.up")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.lensFolded ? "Expand trip lens" : "Fold trip lens")
      }
      if !model.lensFolded {
        switch lens.body {
        case let .meals(days): mealDaysView(days)
        case let .nights(runs): nightRunsView(runs)
        }
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder private func mealDaysView(_ days: [GuideTripLens.MealDay]) -> some View {
    if horizontalSizeClass == .regular {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Day").frame(width: 80, alignment: .leading)
          Text("Lunch").frame(maxWidth: .infinity, alignment: .leading)
          Text("Dinner").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.bold()).foregroundStyle(.secondary)
        ForEach(days) { day in
          HStack(alignment: .top, spacing: 8) {
            Text(day.weekday?.shortLabel ?? "Day \(day.day)").font(.caption.bold()).frame(width: 80, alignment: .leading)
            mealCell(day.lunch, label: "Lunch")
            mealCell(day.dinner, label: "Dinner")
          }
          if !day.alsoThatDay.isEmpty { alsoThatDay(day.alsoThatDay).padding(.leading, 88) }
        }
      }
    } else {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 8) {
          ForEach(days) { day in
            VStack(alignment: .leading, spacing: 6) {
              Text(day.weekday?.shortLabel ?? "Day \(day.day)").font(.caption.bold())
              mealCell(day.lunch, label: "L")
              mealCell(day.dinner, label: "D")
              if !day.alsoThatDay.isEmpty { alsoThatDay(day.alsoThatDay) }
            }
            .frame(width: 155, alignment: .leading)
            .padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }
    }
  }

  private func alsoThatDay(_ stops: [GuideTripLens.SlotStop]) -> some View {
    Text("Also: \(stops.map(\.title).joined(separator: ", "))")
      .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
  }

  private func lensHeading(_ lens: GuideTripLens) -> String {
    switch lens.body {
    case let .meals(days):
      guard let first = days.first?.day, let last = days.last?.day else { return "Days in \(model.region?.name ?? "")" }
      return "Days \(first)–\(last) in \(model.region?.name ?? "")"
    case let .nights(runs):
      let spans = runs.compactMap { run -> ClosedRange<Int>? in
        switch run {
        case let .open(nights): nights
        case let .stay(_, _, _, _, nights): nights
        }
      }
      guard let first = spans.first?.lowerBound, let last = spans.last?.upperBound else { return "Nights" }
      return first == last ? "Night \(first)" : "Nights \(first)–\(last)"
    }
  }

  private func nightRunsView(_ runs: [GuideTripLens.NightRun]) -> some View {
    Group {
      if horizontalSizeClass == .regular {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(runs.enumerated()), id: \.offset) { _, run in nightRunView(run) }
        }
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
              nightRunView(run).padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
          }
        }
      }
    }
  }

  @ViewBuilder private func nightRunView(_ run: GuideTripLens.NightRun) -> some View {
      switch run {
      case let .open(nights):
        Text("Open · Night \(nights.lowerBound)\(nights.lowerBound == nights.upperBound ? "" : "–\(nights.upperBound)")")
          .font(.subheadline).padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])))
      case let .stay(_, ideaID, title, booked, nights):
        Button { model.tripStopTapped(ideaID) } label: {
          Label("\(title) · Night \(nights.lowerBound)\(nights.lowerBound == nights.upperBound ? "" : "–\(nights.upperBound)")", systemImage: booked ? "checkmark.circle.fill" : "bed.double")
        }.buttonStyle(.plain)
      }
  }

  @ViewBuilder private func mealCell(_ cell: GuideTripLens.MealCell, label: String) -> some View {
    switch cell {
    case .open:
      Text("\(label) · Open").font(.caption).padding(.horizontal, 7).padding(.vertical, 5)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])))
    case let .filled(stops):
      if let stop = stops.first {
        Button { model.tripStopTapped(stop.ideaID) } label: {
          HStack(spacing: 4) {
            if stop.isBooked { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            Text("\(label) · \(stop.title)\(stop.optionCount > 1 ? " · \(stop.optionCount) options" : "")\(stops.count > 1 ? " +\(stops.count - 1)" : "")")
              .italic(stop.isFreeform).lineLimit(1)
          }.font(.caption).padding(.horizontal, 7).padding(.vertical, 5)
            .background(stop.optionCount > 1 ? Color.orange.opacity(0.14) : Color.green.opacity(stop.isBooked ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
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
