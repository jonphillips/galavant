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
