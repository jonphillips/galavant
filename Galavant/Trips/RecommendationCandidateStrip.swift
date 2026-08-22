import GalavantSchema
import SwiftUI

/// The bottom work-queue: every candidate as a compact card, scrolling horizontally,
/// with one always in focus (drives the map + browser above). Secondary actions live
/// in a per-card menu so the row stays short and never wraps — slice 3 grows the
/// focused card into a dossier flyout that reclaims the siblings' width.
struct RecommendationCandidateStrip: View {
  let model: RecommendationWorkspaceModel
  @Environment(\.undoManager) private var undoManager
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
            RecommendationCandidateStripCard(
              model: model,
              candidate: candidate,
              isActive: candidate.id == model.effectiveActiveCandidateID,
              isInChoice: model.choiceCandidateIDs.contains(candidate.id),
              isExpanded: expandedID == candidate.id,
              days: model.tripDays,
              select: { model.candidateTapped(candidate) },
              setExpanded: { expand in
                withAnimation(.snappy(duration: 0.22)) {
                  expandedID = expand ? candidate.id : nil
                }
              },
              toggleChoice: { model.choiceButtonTapped(candidate) },
              save: { model.saveButtonTapped(candidate) },
              addToDay: { day in model.addToDay(candidate, day: day) },
              dismiss: { model.dismissButtonTapped(candidate, undoManager: undoManager) }
            )
          }
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
      }
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
  let isExpanded: Bool
  let days: [RecommendationWorkspaceDay]
  let select: () -> Void
  let setExpanded: (Bool) -> Void
  let toggleChoice: () -> Void
  let save: () -> Void
  let addToDay: (Int?) -> Void
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if isExpanded {
          expandedBody
        } else {
          collapsedBody
        }
      }
      if isActive {
        RecommendationWorkspaceImageDropWell(model: model)
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(backgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay {
      if isActive {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(Color.orange, lineWidth: 2)
      }
    }
  }

  /// Tapping a collapsed card focuses it (drives the map + browser) and opens it;
  /// tapping the expanded card's chevron just collapses it again without touching
  /// any other card. Only one card is expanded at a time.
  private var collapsedBody: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(candidate.title)
          .font(.headline)
          .lineLimit(2)
        Spacer(minLength: 6)
        actionsMenu
      }
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
    .padding(12)
    .frame(width: 280)
    .contentShape(Rectangle())
    .onTapGesture {
      select()
      setExpanded(true)
    }
  }

  private var expandedBody: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Button { setExpanded(false) } label: {
            Image(systemName: "chevron.left")
              .font(.headline)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Collapse")
          Text(candidate.title)
            .font(.headline)
            .lineLimit(3)
        }
        statusLabel
        Spacer(minLength: 0)
        hint
      }
      .frame(width: 190, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture { select() }

      Divider()

      // The dossier that was truncated in the collapsed card, now fully visible —
      // scrolls if it's long, so the strip never has to grow taller.
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
      .frame(width: 300)

      actionsMenu
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

  // Resolved candidates read as "done/mapped" (green) regardless of focus; the
  // focused-but-unresolved card gets a warm tint, everything else stays neutral.
  private var backgroundColor: Color {
    if candidate.isResolved { return Color.green.opacity(0.14) }
    if isActive { return Color.orange.opacity(0.12) }
    return Color.secondary.opacity(0.08)
  }
}
