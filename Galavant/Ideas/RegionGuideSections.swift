import GalavantSchema
import SwiftUI

struct RegionGuideSections<Row: View>: View {
  let guide: RegionGuide
  let lists: [TripIdea.RankedList]
  let selectedList: TripIdea.RankedList?
  let shelfLabel: String
  let onSelectList: (String?) -> Void
  let row: (RegionGuide.Card) -> Row

  var body: some View {
    if guide.sections.isEmpty {
      emptyContent
    } else {
      ForEach(guide.sections) { section in
        RegionGuideCardSection(
          section: section,
          lists: section.id == guide.sections.first?.id ? lists : [],
          selectedList: selectedList,
          onSelectList: onSelectList,
          row: row
        )
      }
    }
  }

  @ViewBuilder private var emptyContent: some View {
    let count = guide.counts[.notForMe, default: 0]
    if lists.isEmpty {
      ContentUnavailableView("Nothing in \(shelfLabel)", systemImage: Icon.ideas.systemName,
        description: Text("\(count) \(count == 1 ? "place is" : "places are") on Not for Me."))
    } else {
      RegionGuideEmptySection(
        message: selectedList.map { "No places in \($0.name) fit this filter." } ?? "Nothing in \(shelfLabel)",
        detail: selectedList == nil
          ? "\(count) \(count == 1 ? "place is" : "places are") on Not for Me."
          : "Choose another list or All places.",
        lists: lists, selectedListName: selectedList?.name, onSelectList: onSelectList)
    }
  }
}

private struct RegionGuideCardSection<Row: View>: View {
  let section: RegionGuide.Section
  let lists: [TripIdea.RankedList]
  let selectedList: TripIdea.RankedList?
  let onSelectList: (String?) -> Void
  let row: (RegionGuide.Card) -> Row

  var body: some View {
    Section {
      ForEach(section.cards) { card in row(card) }
    } header: {
      RegionGuideListHeader(
        title: selectedList == nil ? section.title : nil, lists: lists,
        selectedListName: selectedList?.name, onSelectList: onSelectList)
    }
  }
}

private struct RegionGuideListHeader: View {
  let title: String?
  let lists: [TripIdea.RankedList]
  let selectedListName: String?
  let onSelectList: (String?) -> Void

  var body: some View {
    HStack {
      if let title { Text(title) }
      if title != nil { Spacer() }
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

private struct RegionGuideEmptySection: View {
  let message: String
  let detail: String
  let lists: [TripIdea.RankedList]
  let selectedListName: String?
  let onSelectList: (String?) -> Void

  var body: some View {
    Section {
      ContentUnavailableView(message, systemImage: Icon.ideas.systemName, description: Text(detail))
    } header: {
      RegionGuideListHeader(
        title: nil, lists: lists, selectedListName: selectedListName, onSelectList: onSelectList)
    }
  }
}
