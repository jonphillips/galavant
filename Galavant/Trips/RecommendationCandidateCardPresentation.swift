import GalavantSchema
import SwiftUI

/// Shared candidate content for the strip, dossier, and compact-sheet presentations.
/// The iPhone surface can use the same state and actions without taking on any of
/// the regular-width strip's overlay mechanics.
struct RecommendationCandidateCardPresentation<BottomContent: View>: View {
  enum Layout {
    case compact
    case dossier
    case sheet
  }

  let candidate: RecommendationWorkspaceCandidate
  let layout: Layout
  let isInChoice: Bool
  let days: [RecommendationWorkspaceDay]
  let select: () -> Void
  let collapse: () -> Void
  let toggleChoice: () -> Void
  let save: () -> Void
  let addToDay: (Int?) -> Void
  let disconnect: () -> Void
  let dismiss: () -> Void
  let dossierBottom: () -> BottomContent

  init(
    candidate: RecommendationWorkspaceCandidate,
    layout: Layout,
    isInChoice: Bool,
    days: [RecommendationWorkspaceDay],
    select: @escaping () -> Void,
    collapse: @escaping () -> Void,
    toggleChoice: @escaping () -> Void,
    save: @escaping () -> Void,
    addToDay: @escaping (Int?) -> Void,
    disconnect: @escaping () -> Void,
    dismiss: @escaping () -> Void,
    @ViewBuilder dossierBottom: @escaping () -> BottomContent
  ) {
    self.candidate = candidate
    self.layout = layout
    self.isInChoice = isInChoice
    self.days = days
    self.select = select
    self.collapse = collapse
    self.toggleChoice = toggleChoice
    self.save = save
    self.addToDay = addToDay
    self.disconnect = disconnect
    self.dismiss = dismiss
    self.dossierBottom = dossierBottom
  }

  var body: some View {
    switch layout {
    case .compact:
      compactBody
    case .dossier:
      dossierBody
    case .sheet:
      sheetBody
    }
  }

  private var compactBody: some View {
    HStack(alignment: .top, spacing: 6) {
      Button(action: select) {
        VStack(alignment: .leading, spacing: 6) {
          Text(candidate.title)
            .font(.headline)
            .lineLimit(2)
          statusLabel
          if let why = candidate.candidate.why {
            Text(why)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }
          Spacer(minLength: 0)
          hint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      actionsMenu
    }
    .padding(12)
    .frame(width: 280, alignment: .topLeading)
    .frame(maxHeight: .infinity, alignment: .topLeading)
  }

  private var dossierBody: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top, spacing: 6) {
          Button(action: collapse) {
            Image(systemName: "chevron.left")
              .font(.headline)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Collapse")

          Button(action: select) {
            Text(candidate.title)
              .font(.headline)
              .lineLimit(3)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        statusLabel
        Spacer(minLength: 0)
        hint
        dossierBottom()
      }
      .frame(width: 230, alignment: .leading)

      Divider()

      // The dossier that is truncated in the compact card stays scrollable so the
      // strip never has to grow taller.
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if let why = candidate.candidate.why { dossierField("Why", why) }
          if let fit = candidate.candidate.fit { dossierField("Fit", fit) }
          if let visit = candidate.candidate.visit { dossierField("Time", visit) }
          if let placementAfter = candidate.candidate.placementAfter {
            dossierField("Placement", "Suggested after \(placementAfter) — choose its placement yourself.")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity)

      actionsMenu
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .padding(12)
  }

  private var sheetBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        Button(action: select) {
          Text(candidate.title)
            .font(.headline)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        actionsMenu
      }

      statusLabel

      VStack(alignment: .leading, spacing: 10) {
        if let why = candidate.candidate.why { dossierField("Why", why) }
        if let fit = candidate.candidate.fit { dossierField("Fit", fit) }
        if let visit = candidate.candidate.visit { dossierField("Time", visit) }
        if let placementAfter = candidate.candidate.placementAfter {
          dossierField("Placement", "Suggested after \(placementAfter) — choose its placement yourself.")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      hint
      dossierBottom()
    }
    .padding(12)
  }

  private var actionsMenu: some View {
    Menu {
      Button(isInChoice ? "Unmark for Choose One" : "Mark for Choose One", systemImage: "smallcircle.filled.circle") {
        toggleChoice()
      }
      Button("Shortlist", systemImage: "star") { save() }
      Menu("Add to Day", systemImage: "calendar.badge.plus") {
        ForEach(days) { day in
          Button {
            addToDay(day.number)
          } label: {
            if let date = day.date {
              Text("Day \(day.number) · \(date, format: .dateTime.weekday(.abbreviated).month().day())")
            } else {
              Text("Day \(day.number)")
            }
          }
        }
        if !days.isEmpty { Divider() }
        Button("To be scheduled") { addToDay(nil) }
      }
      if candidate.isResolved {
        Button("Disconnect Place", systemImage: "mappin.slash") { disconnect() }
      }
      Divider()
      Button("Dismiss", systemImage: "xmark", role: .destructive) { dismiss() }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.title3)
    }
    .accessibilityLabel("Candidate actions")
  }

  private var hasWebsite: Bool {
    !(candidate.idea?.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  // Two independent facts: "Resolved" is the map-item mapping; "Site" is a connected
  // website (the browser's Connect). A candidate can be either, both, or neither.
  private var statusLabel: some View {
    HStack(spacing: 8) {
      HStack(spacing: 4) {
        if candidate.isResolved {
          Image(systemName: "checkmark.seal.fill")
            .foregroundStyle(.green)
        }
        Text(candidate.isResolved ? "Resolved" : "Unresolved")
          .foregroundStyle(candidate.isResolved ? .green : .secondary)
      }
      // Always shown so "linked or not" is legible at a glance: grey = no site,
      // blue = connected, with a bounce the moment the browser's Connect links one.
      Label("Site", systemImage: "link")
        .foregroundStyle(hasWebsite ? Color.blue : Color.gray)
        .symbolEffect(.bounce, value: hasWebsite)
    }
    .font(.caption)
  }

  @ViewBuilder private var hint: some View {
    if candidate.isAwaitingResolutionOnItinerary {
      Label("On itinerary — resolve to upgrade this freeform stop.", systemImage: "calendar.badge.clock")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    } else if !candidate.isResolved {
      Text("Resolve on the map, or add as a freeform stop.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(2)
    }
  }

  private func dossierField(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline)
    }
  }
}
