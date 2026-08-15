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

private struct RecommendationCandidateStripCard: View {
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
    Group {
      if isExpanded {
        expandedBody
      } else {
        collapsedBody
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
      Button("Save to Ideas", systemImage: "lightbulb") { save() }
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
      if hasWebsite {
        Label("Site", systemImage: "link")
          .foregroundStyle(.blue)
      }
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
  @State private var didInitialFrame = false

  var body: some View {
    Map(position: $cameraPosition) {
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
    .onMapCameraChange { context in
      visibleRegion = context.region
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
  }

  private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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
