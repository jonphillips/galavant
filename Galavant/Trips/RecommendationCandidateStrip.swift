import GalavantSchema
import SwiftUI

/// The bottom work-queue: every candidate as a compact card, scrolling horizontally,
/// with one always in focus (drives the map + browser above). Secondary actions live
/// in a per-card menu so the row stays short and never wraps — slice 3 grows the
/// focused card into a dossier flyout that reclaims the siblings' width.
struct RecommendationCandidateStrip: View {
  let model: RecommendationWorkspaceModel
  @Environment(\.undoManager) private var undoManager
  @Namespace private var candidateFlyoutNamespace
  @State private var expandedID: TripIdea.ID?
  @State private var addingCandidate = false
  @State private var newCandidateName = ""

  private var activeChoiceIsSelected: Bool {
    model.effectiveActiveCandidateID.map { model.choiceCandidateIDs.contains($0) } ?? false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Text("Candidates")
          .font(.headline)
        Button {
          newCandidateName = ""
          addingCandidate = true
        } label: {
          Image(systemName: "plus.circle.fill")
            .font(.title3)
        }
        .accessibilityLabel("Add a candidate")
        Spacer()
        // "Choose One" collapses the marked candidates into ONE interchangeable
        // itinerary slot (ADR-0035 alternatives ring): mark 2+, then tap this to
        // make them options you pick between later, instead of separate stops.
        if !model.choiceCandidateIDs.isEmpty {
          Text("^[\(model.choiceCandidateIDs.count) marked](inflect: true)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Button("Choose One") {
          model.chooseOneButtonTapped()
        }
        .disabled(model.choiceCandidateIDs.count < 2 || !activeChoiceIsSelected)
      }
      .padding(.horizontal)
      .padding(.top, 10)
      .padding(.bottom, 6)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(model.candidates) { candidate in
            if expandedID == candidate.id {
              // Keep the queue's geometry stable while the dossier occupies the
              // focused card's reclaimed space above it.
              Color.clear
                .frame(width: 280)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
            } else {
              RecommendationCandidateStripCard(
                model: model,
                candidate: candidate,
                isActive: candidate.id == model.effectiveActiveCandidateID,
                isInChoice: model.choiceCandidateIDs.contains(candidate.id),
                days: model.tripDays,
                namespace: candidateFlyoutNamespace,
                open: {
                  model.candidateTapped(candidate)
                  withAnimation(.snappy(duration: 0.22)) {
                    expandedID = candidate.id
                  }
                },
                toggleChoice: { model.choiceButtonTapped(candidate) },
                save: {
                  model.saveButtonTapped(candidate)
                  expandedID = nil
                },
                addToDay: { day in
                  model.addToDay(candidate, day: day)
                  expandedID = nil
                },
                disconnect: { model.disconnectButtonTapped(candidate) },
                dismiss: {
                  model.dismissButtonTapped(candidate, undoManager: undoManager)
                  expandedID = nil
                }
              )
            }
          }
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
      }
      .overlay(alignment: .bottomLeading) {
        if let expandedID,
           let candidate = model.candidates.first(where: { $0.id == expandedID }) {
          RecommendationCandidateStripFlyout(
            model: model,
            candidate: candidate,
            isActive: candidate.id == model.effectiveActiveCandidateID,
            isInChoice: model.choiceCandidateIDs.contains(candidate.id),
            days: model.tripDays,
            namespace: candidateFlyoutNamespace,
            dismiss: {
              withAnimation(.snappy(duration: 0.22)) {
                self.expandedID = nil
              }
            },
            select: { model.candidateTapped(candidate) },
            toggleChoice: { model.choiceButtonTapped(candidate) },
            save: {
              model.saveButtonTapped(candidate)
              self.expandedID = nil
            },
            addToDay: { day in
              model.addToDay(candidate, day: day)
              self.expandedID = nil
            },
            disconnect: { model.disconnectButtonTapped(candidate) },
            dismissCandidate: {
              model.dismissButtonTapped(candidate, undoManager: undoManager)
              self.expandedID = nil
            }
          )
          .padding(.leading, 12)
          .padding(.bottom, 12)
          .transition(.opacity)
          .zIndex(1)
        }
      }
      .animation(.snappy(duration: 0.22), value: expandedID)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .alert("New candidate", isPresented: $addingCandidate) {
      TextField("Place name", text: $newCandidateName)
      Button("Add") { model.addManualCandidate(named: newCandidateName) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Add a place the AI didn't suggest. It joins the set and resolves on the map like any other candidate.")
    }
  }
}

struct RecommendationCandidateStripCard: View {
  let model: RecommendationWorkspaceModel
  let candidate: RecommendationWorkspaceCandidate
  let isActive: Bool
  let isInChoice: Bool
  let days: [RecommendationWorkspaceDay]
  let namespace: Namespace.ID
  let open: () -> Void
  let toggleChoice: () -> Void
  let save: () -> Void
  let addToDay: (Int?) -> Void
  let disconnect: () -> Void
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      RecommendationCandidateCardPresentation(
        candidate: candidate,
        layout: .compact,
        isInChoice: isInChoice,
        days: days,
        select: open,
        collapse: {},
        toggleChoice: toggleChoice,
        save: save,
        addToDay: addToDay,
        disconnect: disconnect,
        dismiss: dismiss,
        dossierBottom: { EmptyView() }
      )
      if isActive {
        RecommendationWorkspaceImageDropWell(model: model)
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
      }
    }
    // Fix the shell width as well as the compact content width. Without this,
    // the active image well can give a card a different ideal width inside the
    // unconstrained horizontal ScrollView.
    .frame(width: 280, alignment: .top)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(backgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .matchedGeometryEffect(id: candidate.id, in: namespace)
    .overlay {
      if isActive {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(Color.orange, lineWidth: 2)
      }
    }
  }

  // Resolved candidates read as "done/mapped" (green) regardless of focus; the
  // focused-but-unresolved card gets a warm tint, everything else stays neutral.
  private var backgroundColor: Color {
    if candidate.isResolved { return Color.green.opacity(0.14) }
    if isActive { return Color.orange.opacity(0.12) }
    return Color.secondary.opacity(0.08)
  }
}

private struct RecommendationCandidateStripFlyout: View {
  let model: RecommendationWorkspaceModel
  let candidate: RecommendationWorkspaceCandidate
  let isActive: Bool
  let isInChoice: Bool
  let days: [RecommendationWorkspaceDay]
  let namespace: Namespace.ID
  let dismiss: () -> Void
  let select: () -> Void
  let toggleChoice: () -> Void
  let save: () -> Void
  let addToDay: (Int?) -> Void
  let disconnect: () -> Void
  let dismissCandidate: () -> Void

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      Button(action: dismiss) {
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss dossier")
      .accessibilityHint("Returns to the candidate row without changing the focused candidate.")

      GeometryReader { proxy in
        ZStack(alignment: .topLeading) {
          // The tint is intentionally translucent, but the bar material beneath
          // it must be opaque so sibling cards cannot show through the dossier.
          RoundedRectangle(cornerRadius: 12)
            .fill(.bar)
          RoundedRectangle(cornerRadius: 12)
            .fill(backgroundColor)

          RecommendationCandidateCardPresentation(
            candidate: candidate,
            layout: .dossier,
            isInChoice: isInChoice,
            days: days,
            select: select,
            collapse: dismiss,
            toggleChoice: toggleChoice,
            save: save,
            addToDay: addToDay,
            disconnect: disconnect,
            dismiss: dismissCandidate,
            dossierBottom: {
              if isActive {
                RecommendationWorkspaceImageDropWell(model: model)
              }
            }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: proxy.size.width * 0.88, height: proxy.size.height - 12, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .matchedGeometryEffect(id: candidate.id, in: namespace)
        .overlay {
          if isActive {
            RoundedRectangle(cornerRadius: 12)
              .strokeBorder(Color.orange, lineWidth: 2)
          }
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: -4)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var backgroundColor: Color {
    if candidate.isResolved { return Color.green.opacity(0.14) }
    if isActive { return Color.orange.opacity(0.12) }
    return Color.secondary.opacity(0.08)
  }
}

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
