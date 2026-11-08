import GalavantSchema

extension IdeasListModel {
  var isFiltering: Bool {
    selectedRegionID != nil || !selectedKinds.isEmpty || !selectedKindGroups.isEmpty
      || !effectiveSelectedTagIDs.isEmpty || !includeVisited || showMatchesOnly
      || scheduleFilter != nil
  }

  var effectiveSelectedTagIDs: Set<Tag.ID> {
    tagIndex.effectiveSelection(selectedTagIDs)
  }

  var filterSummary: String {
    let index = tagIndex
    let effectiveTagIDs = index.effectiveSelection(selectedTagIDs)
    var parts: [String] = []
    if let region = selectedRegion { parts.append(region.name) }
    if !selectedKinds.isEmpty {
      parts.append(selectedKinds.map(\.label).sorted().joined(separator: ", "))
    }
    if !selectedKindGroups.isEmpty {
      parts.append(IdeaKindGroup.allCases.filter(selectedKindGroups.contains).map(\.label).joined(separator: ", "))
    }
    if !effectiveTagIDs.isEmpty {
      let names = index.tags.filter { effectiveTagIDs.contains($0.id) }.map(\.name)
      parts.append(names.joined(separator: ", "))
    }
    if let scheduleFilter { parts.append(scheduleFilter.label) }
    if !includeVisited { parts.append("hiding visited") }
    if showMatchesOnly { parts.append("matches only") }
    return parts.joined(separator: " · ")
  }
}
