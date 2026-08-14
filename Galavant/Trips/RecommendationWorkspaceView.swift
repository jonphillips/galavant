import GalavantAI
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
        HStack(spacing: 0) {
          RecommendationCandidateRail(model: model)
            .frame(width: 300)
          Divider()
          RecommendationWorkspaceMap(model: model)
            .overlay(alignment: .bottom) {
              ActiveCandidateResolveControls(model: model)
                .padding()
            }
            .frame(minWidth: 340)
          Divider()
          RecommendationWorkspaceBrowser(model: model)
            .frame(minWidth: 440, maxWidth: .infinity)
        }
      } else {
        RecommendationWorkspaceCompactLayout(model: model)
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
