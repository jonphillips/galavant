import GalavantAI
import GalavantPlaces
import GalavantSchema
import MapKit
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
    .overlay(alignment: .topTrailing) {
      Button("Done") { dismiss() }
        .buttonStyle(.bordered)
        .padding()
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
    .task { model.task() }
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
            .frame(width: geo.size.width * 2 / 3)
          Divider()
          RecommendationWorkspaceMap(model: model)
            .overlay(alignment: .bottom) {
              ActiveCandidateResolveControls(model: model)
                .padding()
            }
        }
      }
      Divider()
      RecommendationCandidateStrip(model: model)
        .frame(height: 220)
    }
  }
}

/// The bottom work-queue: every candidate as a compact card, scrolling horizontally,
/// with one always in focus (drives the map + browser above). Secondary actions live
/// in a per-card menu so the row stays short and never wraps — slice 3 grows the
/// focused card into a dossier flyout that reclaims the siblings' width.
private struct RecommendationCandidateStrip: View {
  let model: RecommendationWorkspaceModel
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
        Button("Choose One (\(model.choiceCandidateIDs.count))") {
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
              candidate: candidate,
              isActive: candidate.id == model.effectiveActiveCandidateID,
              isInChoice: model.choiceCandidateIDs.contains(candidate.id),
              select: { model.candidateTapped(candidate) },
              toggleChoice: { model.choiceButtonTapped(candidate) },
              save: { model.saveButtonTapped(candidate) },
              addToItinerary: { model.addToItineraryButtonTapped(candidate) },
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
  }
}

private struct RecommendationCandidateStripCard: View {
  let candidate: RecommendationWorkspaceCandidate
  let isActive: Bool
  let isInChoice: Bool
  let select: () -> Void
  let toggleChoice: () -> Void
  let save: () -> Void
  let addToItinerary: () -> Void
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(candidate.title)
          .font(.headline)
          .lineLimit(2)
        Spacer(minLength: 6)
        Menu {
          Button(isInChoice ? "Remove from Choose One" : "Add to Choose One", systemImage: "smallcircle.filled.circle") {
            toggleChoice()
          }
          Button("Save to Ideas", systemImage: "lightbulb") { save() }
          Button("Add to Itinerary", systemImage: "calendar.badge.plus") { addToItinerary() }
          Divider()
          Button("Dismiss", systemImage: "xmark", role: .destructive) { dismiss() }
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.title3)
        }
        .accessibilityLabel("Candidate actions")
      }
      Text(candidate.isResolved ? "Resolved" : "Unresolved")
        .font(.caption)
        .foregroundStyle(candidate.isResolved ? .green : .secondary)
      if let why = candidate.candidate.why {
        Text(why)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      Spacer(minLength: 0)
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
    .padding(12)
    .frame(width: 280)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(isActive ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay {
      if isActive {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(Color.orange, lineWidth: 2)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { select() }
  }
}

private struct RecommendationCandidateRail: View {
  let model: RecommendationWorkspaceModel
  var research: (() -> Void)? = nil
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
        if let research {
          Button("Research", action: research)
        }
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
        LazyVStack(spacing: 10) {
          ForEach(model.candidates) { candidate in
            RecommendationCandidateCard(
              candidate: candidate,
              isActive: candidate.id == model.effectiveActiveCandidateID,
              isInChoice: model.choiceCandidateIDs.contains(candidate.id),
              select: { model.candidateTapped(candidate) },
              toggleChoice: { model.choiceButtonTapped(candidate) },
              save: { model.saveButtonTapped(candidate) },
              addToItinerary: { model.addToItineraryButtonTapped(candidate) },
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

private struct RecommendationCandidateCard: View {
  let candidate: RecommendationWorkspaceCandidate
  let isActive: Bool
  let isInChoice: Bool
  let select: () -> Void
  let toggleChoice: () -> Void
  let save: () -> Void
  let addToItinerary: () -> Void
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: select) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            Text(candidate.title)
              .font(.headline)
            Spacer()
            Text(candidate.isResolved ? "Resolved" : "Unresolved")
              .font(.caption)
              .foregroundStyle(candidate.isResolved ? .green : .secondary)
          }
          if let why = candidate.candidate.why {
            LabeledContent("Why", value: why)
              .font(.subheadline)
          }
          if let fit = candidate.candidate.fit {
            LabeledContent("Fit", value: fit)
              .font(.subheadline)
          }
          if let visit = candidate.candidate.visit {
            LabeledContent("Time", value: visit)
              .font(.subheadline)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isActive ? .isSelected : [])
      if candidate.isAwaitingResolutionOnItinerary {
        Label("On itinerary — resolve to upgrade this freeform stop.", systemImage: "calendar.badge.clock")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        HStack {
          Button(isInChoice ? "Chosen" : "Choose") { toggleChoice() }
          Button("Save to Ideas") { save() }
          Button("Add to Itinerary") { addToItinerary() }
          Button("Dismiss", role: .destructive) { dismiss() }
        }
        .buttonStyle(.bordered)
        if !candidate.isResolved {
          Text("Resolve first for a mapped place, or add this freeform stop now.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let placementAfter = candidate.candidate.placementAfter {
          Text("Suggested after \(placementAfter) — choose its placement yourself.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isActive ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }
}

private struct RecommendationWorkspaceMap: View {
  let model: RecommendationWorkspaceModel
  @State private var cameraPosition: MapCameraPosition = .automatic
  @State private var visibleRegion: MKCoordinateRegion?

  var body: some View {
    Map(position: $cameraPosition) {
      ForEach(model.itineraryMarkers) { marker in
        Marker(marker.title, systemImage: "mappin", coordinate: coordinate(marker.latitude, marker.longitude))
          .tint(.blue)
      }
      ForEach(model.candidateMarkers) { marker in
        Marker(
          marker.title,
          systemImage: markerSymbol(marker.state),
          coordinate: coordinate(marker.latitude, marker.longitude)
        )
        .tint(markerColor(marker.state))
      }
      ForEach(model.resolveResults) { place in
        Marker(place.name, systemImage: "mappin.and.ellipse", coordinate: coordinate(place.latitude, place.longitude))
          .tint(.purple)
      }
    }
    // Search the map to jump straight to a place instead of panning to hunt for it —
    // the same overlay the trip and pool maps use. Locate-only: it reframes the camera;
    // resolving a candidate is still "Use This Place" (ADR-0036 keeps the pool clean).
    .overlay(alignment: .top) {
      MapPlaceSearchOverlay(visibleRegion: visibleRegion) { place in
        cameraPosition = .region(
          MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
          )
        )
      }
    }
    .onMapCameraChange { context in
      visibleRegion = context.region
    }
    .onChange(of: model.mapViewport, initial: true) { _, viewport in
      guard let viewport else { return }
      cameraPosition = .region(
        MKCoordinateRegion(
          center: CLLocationCoordinate2D(
            latitude: viewport.centerLatitude,
            longitude: viewport.centerLongitude
          ),
          span: MKCoordinateSpan(
            latitudeDelta: viewport.latitudeDelta,
            longitudeDelta: viewport.longitudeDelta
          )
        )
      )
    }
  }

  private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  private func markerSymbol(_ state: CandidateMapMarkerState) -> String {
    switch state {
    case .fuzzy: "sparkles"
    case .resolved: "mappin.circle.fill"
    }
  }

  private func markerColor(_ state: CandidateMapMarkerState) -> Color {
    switch state {
    case let .fuzzy(isActive), let .resolved(isActive): isActive ? .orange : .gray
    }
  }
}

private struct ActiveCandidateResolveControls: View {
  let model: RecommendationWorkspaceModel

  var body: some View {
    VStack(spacing: 8) {
      if let active = model.activeCandidate {
        Button("Use This Place for \(active.title)") {
          Task { await model.useThisPlaceButtonTapped() }
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
      .sheet(isPresented: $candidateRailIsPresented) {
        VStack(spacing: 0) {
          ActiveCandidateResolveControls(model: model)
            .padding()
          Divider()
          RecommendationCandidateRail(model: model) {
            researchIsPresented = true
          }
        }
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
    if let request = model.browserLoadRequest {
      BrowserScreen(context: .recommendation(request))
        .environment(browserModel)
    } else {
      ContentUnavailableView {
        Label("No Browser Target", systemImage: "safari")
      } description: {
        Text(noBrowserTargetDescription)
      }
    }
  }

  private var noBrowserTargetDescription: String {
    guard let candidate = model.activeCandidate else {
      return "Select a candidate to research."
    }
    return candidate.isResolved
      ? "No website on file for this place."
      : "Resolve this candidate to load its official website."
  }
}
