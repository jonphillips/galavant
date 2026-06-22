import GalavantSchema
import SwiftUI

/// The Ideas screen's filter toolbar menu — region (eternal pool only), kinds,
/// tags, visited/matches toggles, and sort. Extracted from `IdeasScreen` so the
/// screen stays a composition of its parts. The Manage… entries hand back up via
/// bindings the parent owns (they present sheets at screen scope).
struct IdeasFilterMenu: View {
  @Bindable var model: IdeasListModel
  @Binding var managingRegions: Bool
  @Binding var managingTags: Bool

  var body: some View {
    Menu {
      // A trip capsule supplies the geography; the manual region picker only
      // applies to the eternal "All" pool.
      if model.activeTripID == nil {
        Menu("Region") {
          Button {
            model.selectedRegionID = nil
          } label: {
            checked("All regions", on: model.selectedRegionID == nil)
          }
          ForEach(model.sortedRegions) { region in
            Button {
              model.selectedRegionID = region.id
            } label: {
              checked(region.name, on: model.selectedRegionID == region.id)
            }
          }
          if !model.regions.isEmpty {
            Divider()
            Button("Manage Regions…", systemImage: Icon.manage.systemName) {
              managingRegions = true
            }
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
        if !model.tags.isEmpty {
          Divider()
          Button("Manage Tags…", systemImage: Icon.manage.systemName) {
            managingTags = true
          }
        }
      }
      Toggle("Show visited", isOn: $model.includeVisited)
      Toggle("Matches only", isOn: $model.showMatchesOnly)
      Menu("Sort") {
        ForEach(IdeasListModel.IdeaSort.allCases, id: \.self) { sort in
          Button {
            model.sortMode = sort
          } label: {
            checked(sort.label, on: model.sortMode == sort)
          }
        }
      }
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
