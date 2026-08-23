import Foundation
import GalavantAI
import GalavantPlaces
import GalavantSchema
import MapKit
import SwiftUI
import UniformTypeIdentifiers

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

private struct RecommendationWorkspaceMap: View {
  let model: RecommendationWorkspaceModel
  @State private var cameraPosition: MapCameraPosition = .automatic
  @State private var mapSelection: MapSelection<UUID>?
  @State private var visibleRegion: MKCoordinateRegion?
  @State private var didInitialFrame = false

  var body: some View {
    PlaceSelectionMap(
      cameraPosition: $cameraPosition,
      selection: $mapSelection,
      visibleRegion: $visibleRegion,
      presentationPolicy: .immediate,
      onSelectPlace: { place in model.resolveResultTapped(place) }
    ) {
      ForEach(model.itineraryMarkers) { marker in
        Marker(marker.title, systemImage: "mappin", coordinate: coordinate(marker.latitude, marker.longitude))
          .tint(.blue)
      }
      ForEach(model.candidateMarkers) { marker in
        if isActiveMarker(marker.state) {
          // The focused candidate is the subject of "Use This Place" — draw it as a
          // large ringed pin so it's unmistakable which location that button acts on.
          Annotation(marker.title, coordinate: coordinate(marker.latitude, marker.longitude)) {
            activeCandidatePin(marker.state)
          }
        } else {
          Marker(
            marker.title,
            systemImage: markerSymbol(marker.state),
            coordinate: coordinate(marker.latitude, marker.longitude)
          )
          .tint(markerColor(marker.state))
        }
      }
      ForEach(model.resolveResults) { place in
        // Confirmable matches — big labeled pins so you can see exactly what
        // "Use This Place" will pick before committing to one.
        Annotation(place.name, coordinate: coordinate(place.latitude, place.longitude)) {
          resolveResultPin
        }
      }
    }
    // Search the map to jump straight to a place. Picking a match resolves the
    // focused candidate to it directly (no second "Use This Place" tap); the button
    // stays for the manual "pan, tap a POI, confirm" path.
    .overlay(alignment: .top) {
      MapPlaceSearchOverlay(
        visibleRegion: visibleRegion,
        // Bias the search toward where the candidate/trip actually is, not the camera
        // box — otherwise a resolve zoom pinholes it and the next candidate finds nothing.
        searchRegions: model.candidateSearchRegions,
        biased: true,
        // Don't prefill for an already-mapped candidate — the auto-search just
        // litters the map with matches over a place that's already pinned.
        seedQuery: model.activeCandidate.flatMap { $0.isResolved ? nil : $0.title }
      ) { place in
        cameraPosition = .region(
          MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
          )
        )
        model.resolveResultTapped(place)
      }
    }
    // Frame the set once, on load. After that the camera stays put through resolves
    // and searches, so a freshly mapped pin doesn't get yanked out from under you.
    .onChange(of: model.mapViewport, initial: true) { _, viewport in
      guard !didInitialFrame, let viewport else { return }
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
      didInitialFrame = true
    }
    // Switching candidates pans to keep the focused pin in view for relative context —
    // but only expands the current frame when the pin is off-screen, so it never yanks
    // a pin that's already visible and never zooms tight onto it.
    .onChange(of: model.effectiveActiveCandidateID) { _, _ in
      guard let location = model.activeCandidateLocation else { return }
      let target = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
      guard let current = visibleRegion else {
        withAnimation {
          cameraPosition = .region(
            MKCoordinateRegion(center: target, span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))
          )
        }
        return
      }
      guard !region(current, contains: target) else { return }
      withAnimation { cameraPosition = .region(region(current, including: target)) }
    }
  }

  private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  private func region(_ region: MKCoordinateRegion, contains coordinate: CLLocationCoordinate2D) -> Bool {
    abs(coordinate.latitude - region.center.latitude) <= region.span.latitudeDelta / 2
      && abs(coordinate.longitude - region.center.longitude) <= region.span.longitudeDelta / 2
  }

  /// The smallest region covering `region` plus `coordinate`, with a little margin so
  /// the newly included pin isn't jammed against the edge.
  private func region(_ region: MKCoordinateRegion, including coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
    let minLatitude = min(region.center.latitude - region.span.latitudeDelta / 2, coordinate.latitude)
    let maxLatitude = max(region.center.latitude + region.span.latitudeDelta / 2, coordinate.latitude)
    let minLongitude = min(region.center.longitude - region.span.longitudeDelta / 2, coordinate.longitude)
    let maxLongitude = max(region.center.longitude + region.span.longitudeDelta / 2, coordinate.longitude)
    return MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: (minLatitude + maxLatitude) / 2,
        longitude: (minLongitude + maxLongitude) / 2
      ),
      span: MKCoordinateSpan(
        latitudeDelta: (maxLatitude - minLatitude) * 1.3,
        longitudeDelta: (maxLongitude - minLongitude) * 1.3
      )
    )
  }

  private func isActiveMarker(_ state: CandidateMapMarkerState) -> Bool {
    switch state {
    case let .fuzzy(isActive), let .resolved(isActive): isActive
    }
  }

  @ViewBuilder private func activeCandidatePin(_ state: CandidateMapMarkerState) -> some View {
    let resolved = if case .resolved = state { true } else { false }
    ZStack {
      Circle()
        .fill((resolved ? Color.green : Color.orange).opacity(0.28))
        .frame(width: 48, height: 48)
      Image(systemName: resolved ? "mappin.circle.fill" : "sparkles")
        .font(.title)
        .foregroundStyle(resolved ? Color.green : Color.orange)
    }
    .shadow(radius: 3)
  }

  private var resolveResultPin: some View {
    Image(systemName: "mappin.circle.fill")
      .font(.largeTitle)
      .foregroundStyle(.purple)
      .background(Circle().fill(.white).padding(4))
      .shadow(radius: 3)
  }

  private func markerSymbol(_ state: CandidateMapMarkerState) -> String {
    switch state {
    case .fuzzy: "sparkles"
    case .resolved: "mappin.circle.fill"
    }
  }

  private func markerColor(_ state: CandidateMapMarkerState) -> Color {
    switch state {
    // Resolved (mapped) candidates stay green whether or not they're the focused
    // one, so the whole set's confirmed geography accumulates on the map. The
    // focused candidate is orange; unmapped fuzzy guesses are muted grey.
    case let .fuzzy(isActive): isActive ? .orange : .gray
    case let .resolved(isActive): isActive ? .orange : .green
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

struct RecommendationWorkspaceImageDropWell: View {
  let model: RecommendationWorkspaceModel
  @State private var isTargeted = false

  private var candidateTitle: String {
    model.activeCandidate?.title ?? "candidate"
  }

  private var canAcceptDrop: Bool {
    model.activeCandidate?.idea != nil
  }

  var body: some View {
    // One compact row: the card above already names the candidate, so the well is
    // just the drop hint + Paste, keeping the strip card short.
    HStack(spacing: 8) {
      Label(
        canAcceptDrop ? "Drop a photo" : "Resolve first to add photos",
        systemImage: canAcceptDrop ? "photo.badge.plus" : "photo.slash"
      )
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
      Spacer(minLength: 4)
      PasteButton(supportedContentTypes: [.image]) { providers in
        Task {
          for provider in providers {
            guard let pastedImage = await droppedImage(from: provider) else {
              model.imageDropProviderFailed()
              continue
            }
            await model.attachDroppedImage(
              pastedImage.data,
              sourceURL: pastedImage.url?.absoluteString
            )
          }
        }
      }
      .labelStyle(.iconOnly)
      .buttonBorderShape(.capsule)
      .controlSize(.small)
      .disabled(!canAcceptDrop)
      .accessibilityLabel("Paste photo to \(candidateTitle)")
    }
    .foregroundStyle(canAcceptDrop ? .primary : .secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(
          isTargeted && canAcceptDrop
            ? Color.accentColor.opacity(0.22)
            : canAcceptDrop
              ? Color.black.opacity(0.08)
              : Color.secondary.opacity(0.12)
        )
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          isTargeted && canAcceptDrop ? Color.accentColor : Color.clear,
          lineWidth: 2
        )
    }
    .contentShape(Rectangle())
    .onDrop(of: [.image, .url], isTargeted: $isTargeted) { providers in
      guard canAcceptDrop else { return false }
      Task {
        for provider in providers {
          guard let droppedImage = await droppedImage(from: provider) else {
            model.imageDropProviderFailed()
            continue
          }
          await model.attachDroppedImage(droppedImage.data, sourceURL: droppedImage.url?.absoluteString)
        }
      }
      return true
    }
    .disabled(!canAcceptDrop)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Add photo to \(candidateTitle)")
    .accessibilityHint(
      canAcceptDrop
        ? "Drop or paste an image from the research browser."
        : "Resolve this candidate first to add photos."
    )
  }

  private struct DroppedImage {
    let data: Data
    let url: URL?
  }

  private func droppedImage(from provider: NSItemProvider) async -> DroppedImage? {
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      guard let data = await loadImageData(from: provider) else { return nil }
      return DroppedImage(data: data, url: await loadURL(from: provider))
    }

    guard
      provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
      let url = await loadURL(from: provider),
      let (data, _) = try? await URLSession.shared.data(from: url)
    else {
      return nil
    }
    return DroppedImage(data: data, url: url)
  }

  private func loadImageData(from provider: NSItemProvider) async -> Data? {
    await loadData(from: provider, typeIdentifier: UTType.image.identifier)
  }

  private func loadURL(from provider: NSItemProvider) async -> URL? {
    guard let data = await loadData(from: provider, typeIdentifier: UTType.url.identifier) else {
      return nil
    }
    if let url = URL(dataRepresentation: data, relativeTo: nil) {
      return url
    }
    guard let string = String(data: data, encoding: .utf8) else { return nil }
    return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
    await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
        continuation.resume(returning: data)
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
