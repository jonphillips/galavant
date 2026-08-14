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
            .frame(minWidth: 340)
          Divider()
          RecommendationBrowserPlaceholder()
            .frame(minWidth: 440, maxWidth: .infinity)
        }
      } else {
        VStack(spacing: 0) {
          RecommendationWorkspaceMap(model: model)
          Divider()
          RecommendationCandidateRail(model: model)
            .frame(maxHeight: 330)
        }
      }
    }
    .overlay(alignment: .topTrailing) {
      Button("Done") { dismiss() }
        .buttonStyle(.bordered)
        .padding()
    }
    .task { model.task() }
  }
}

private struct RecommendationCandidateRail: View {
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
      HStack {
        Button(isInChoice ? "Chosen" : "Choose") { toggleChoice() }
        Button("Save to Ideas") { save() }
        Button("Dismiss", role: .destructive) { dismiss() }
      }
      .buttonStyle(.bordered)
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
    ZStack(alignment: .bottom) {
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
      .padding()
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

private struct RecommendationBrowserPlaceholder: View {
  var body: some View {
    ContentUnavailableView {
      Label("Research", systemImage: "safari")
    } description: {
      Text("Browser research arrives in the next phase.")
    }
  }
}
