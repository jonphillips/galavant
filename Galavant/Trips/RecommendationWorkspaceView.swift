import GalavantAI
import GalavantSchema
import SwiftUI

struct RecommendationWorkspaceHost: View {
  @State private var model: RecommendationWorkspaceModel

  init(tripID: Trip.ID, sessionID: HandoffSession.ID) {
    _model = State(initialValue: RecommendationWorkspaceModel(tripID: tripID, sessionID: sessionID))
  }

  var body: some View {
    RecommendationWorkspaceView(model: model)
  }
}

struct RecommendationWorkspaceView: View {
  let model: RecommendationWorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var usesColumn: Bool { horizontalSizeClass == .regular }

  var body: some View {
    Group {
      if !model.hasLoadedCandidateSet {
        ProgressView("Loading recommendations…")
      } else if model.candidates.isEmpty {
        ContentUnavailableView {
          Label("Candidate Set Complete", systemImage: "checkmark.circle")
        } description: {
          Text("Every candidate in this handoff has been saved or dismissed.")
        } actions: {
          Button("Done") { dismiss() }
        }
      } else if usesColumn {
        RecommendationWorkspaceCockpit(model: model)
      } else {
        RecommendationWorkspaceCompactLayout(model: model) { dismiss() }
      }
    }
    .alert(
      "Already on your trip",
      isPresented: Binding(
        get: { model.pendingReconcile != nil },
        set: { if !$0 { model.pendingReconcile = nil } }
      )
    ) {
      Button("Merge") { model.resolveReconcileChoice(.merge) }
        .keyboardShortcut(.defaultAction)
      Button("Keep Both", role: .cancel) { model.resolveReconcileChoice(.keepBoth) }
    } message: {
      if let collision = model.pendingReconcile {
        Text("This place is already \(collision.existingStatus.label.lowercased()) in this trip. Merge the two rationales, or keep both rows?")
      }
    }
    .overlay(alignment: .top) {
      if let status = model.workspaceStatus {
        RecommendationWorkspaceFlash(status: status)
          .padding()
          .transition(.move(edge: .top).combined(with: .opacity))
          .task(id: status.message) {
            try? await Task.sleep(for: .seconds(4))
            guard model.workspaceStatus == status else { return }
            withAnimation(.snappy) {
              model.workspaceStatus = nil
            }
          }
      }
    }
    .task { await model.task() }
  }
}

private struct RecommendationWorkspaceFlash: View {
  let status: RecommendationWorkspaceStatus

  private var tint: Color {
    status.kind == .success ? .green : .red
  }

  private var systemImage: String {
    status.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
  }

  var body: some View {
    Label(status.message, systemImage: systemImage)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.primary)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(.regularMaterial, in: Capsule())
      .overlay {
        Capsule().strokeBorder(tint.opacity(0.65), lineWidth: 1.5)
      }
      .shadow(radius: 8)
      .accessibilityAddTraits(.isStaticText)
  }
}

/// The regular-width cockpit (ADR-0037): research pane and map stacked on top, the
/// candidate work-queue as a strip along the bottom. Browser gets two-thirds because
/// "do I actually want this" is the slow decision; the map's third is enough to answer
/// "does it make geographic sense." The bottom strip keeps the whole queue in view
/// while one candidate is in focus above.
private struct RecommendationWorkspaceCockpit: View {
  let model: RecommendationWorkspaceModel

  var body: some View {
    VStack(spacing: 0) {
      GeometryReader { geo in
        HStack(spacing: 0) {
          RecommendationWorkspaceBrowser(model: model)
            .frame(width: geo.size.width * 2 / 3, alignment: .top)
            // Keep the browser's field/action bars clear of the candidate divider.
            // WebBrowserView owns its bottom chrome, so give that chrome a small
            // breathing room inside the cockpit rather than shrinking the queue.
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
          Divider()
          RecommendationWorkspaceMap(model: model)
            .overlay(alignment: .bottom) {
              ActiveCandidateResolveControls(model: model)
                .padding()
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
      }
      Divider()
      RecommendationCandidateStrip(model: model)
        .frame(height: 220)
    }
  }
}

private struct ActiveCandidateResolveControls: View {
  let model: RecommendationWorkspaceModel

  var body: some View {
    VStack(spacing: 8) {
      if model.activeCandidate != nil {
        Button {
          Task { await model.useThisPlaceButtonTapped() }
        } label: {
          Label("Connect", systemImage: "mappin.and.ellipse")
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
      }
      if !model.resolveResults.isEmpty {
        ScrollView(.horizontal) {
          HStack {
            ForEach(model.resolveResults) { place in
              Button(place.name) { model.resolveResultTapped(place) }
                .buttonStyle(.bordered)
            }
          }
        }
      }
    }
  }
}

private struct RecommendationWorkspaceCompactLayout: View {
  let model: RecommendationWorkspaceModel
  let dismissWorkspace: () -> Void
  @State private var candidateRailIsPresented = true
  @State private var candidateRailDetent: PresentationDetent = .fraction(0.4)
  @State private var researchIsPresented = false

  var body: some View {
    RecommendationWorkspaceMap(model: model)
      .ignoresSafeArea(.container, edges: .bottom)
      .overlay(alignment: .bottom) {
        ActiveCandidateResolveControls(model: model)
          .padding()
      }
      .sheet(isPresented: $candidateRailIsPresented) {
        RecommendationWorkspaceCompactCandidateSheet(
          model: model,
          research: { researchIsPresented = true }
        )
        .safeAreaInset(edge: .top, alignment: .trailing) {
          Button("Done", action: dismissWorkspace)
            .buttonStyle(.bordered)
            .padding(.horizontal)
        }
        .fullScreenCover(isPresented: $researchIsPresented) {
          RecommendationWorkspaceResearchBrowser(model: model)
        }
        .presentationDetents([.fraction(0.4), .large], selection: $candidateRailDetent)
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.4)))
        .presentationBackground(.regularMaterial)
        .interactiveDismissDisabled(true)
      }
  }
}

private struct RecommendationWorkspaceCompactCandidateSheet: View {
  let model: RecommendationWorkspaceModel
  let research: () -> Void
  @Environment(\.undoManager) private var undoManager

  private var activeChoiceIsSelected: Bool {
    model.effectiveActiveCandidateID.map { model.choiceCandidateIDs.contains($0) } ?? false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Candidates")
          .font(.headline)
        Spacer()
        Button("Research", action: research)
          .disabled(model.activeCandidate == nil)
        Button("Choose One (\(model.choiceCandidateIDs.count))") {
          model.chooseOneButtonTapped()
        }
        .disabled(
          model.choiceCandidateIDs.count < 2
            || !activeChoiceIsSelected
        )
      }
      .padding()

      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(model.candidates) { candidate in
            RecommendationWorkspaceCompactCandidate(
              model: model,
              candidate: candidate,
              isActive: candidate.id == model.effectiveActiveCandidateID,
              isInChoice: model.choiceCandidateIDs.contains(candidate.id),
              select: { model.candidateTapped(candidate) },
              toggleChoice: { model.choiceButtonTapped(candidate) },
              save: { model.saveButtonTapped(candidate) },
              addToDay: { day in model.addToDay(candidate, day: day) },
              disconnect: { model.disconnectButtonTapped(candidate) },
              dismiss: { model.dismissButtonTapped(candidate, undoManager: undoManager) }
            )
          }
        }
        .padding(.horizontal)
        .padding(.bottom)
      }
    }
    .background(.bar)
  }
}

private struct RecommendationWorkspaceCompactCandidate: View {
  let model: RecommendationWorkspaceModel
  let candidate: RecommendationWorkspaceCandidate
  let isActive: Bool
  let isInChoice: Bool
  let select: () -> Void
  let toggleChoice: () -> Void
  let save: () -> Void
  let addToDay: (Int?) -> Void
  let disconnect: () -> Void
  let dismiss: () -> Void

  var body: some View {
    RecommendationCandidateCardPresentation(
      candidate: candidate,
      layout: .sheet,
      isInChoice: isInChoice,
      days: model.tripDays,
      select: select,
      collapse: {},
      toggleChoice: toggleChoice,
      save: save,
      addToDay: addToDay,
      disconnect: disconnect,
      dismiss: dismiss,
      dossierBottom: {
        if isActive {
          RecommendationWorkspaceImageDropWell(model: model)
            .padding(.top, 4)
        }
      }
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay {
      if isActive {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(Color.orange, lineWidth: 2)
      }
    }
    .accessibilityAddTraits(isActive ? .isSelected : [])
  }

  private var backgroundColor: Color {
    if candidate.isResolved { return Color.green.opacity(0.14) }
    if isActive { return Color.orange.opacity(0.12) }
    return Color.secondary.opacity(0.08)
  }
}

private struct RecommendationWorkspaceResearchBrowser: View {
  let model: RecommendationWorkspaceModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      RecommendationWorkspaceBrowser(model: model)
        .navigationTitle("Research")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
  }
}

private struct RecommendationWorkspaceBrowser: View {
  let model: RecommendationWorkspaceModel
  @State private var browserModel = BrowserScreenModel()

  var body: some View {
    // One structural `BrowserScreen` — never an `if/else` between two. Both branches
    // shared the single long-lived `WebPage` (`browserModel.page`), so flipping the
    // condition (e.g. selecting a candidate) mounted a second `WebView` over that page
    // while the first was still transitioning out. WebKit allows only one `WebView` per
    // `WebPage`, so the second `makeViewProvider` traps (EXC_BREAKPOINT in
    // _WebKit_SwiftUI). Computing the context keeps one WebView bound to the page and
    // updates it in place. A nameless candidate falls back to `.library` rather than
    // dead-ending, so you can still search for a related site.
    BrowserScreen(
      context: model.browserLoadRequest.map(BrowserScreenContext.recommendation) ?? .library
    )
    .environment(browserModel)
  }
}
