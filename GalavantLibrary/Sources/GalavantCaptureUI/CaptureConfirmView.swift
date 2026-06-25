import GalavantPlaces
import GalavantSchema
import MapKit
import SwiftUI

/// The confirm-and-tweak sheet shown when a page is captured — from the share
/// extension *or* the in-app browser (Jon's choice: vet captures at the source). The
/// `CaptureModel` does the parse + Apple Maps match (including the ADR-0019 "already in
/// your pool" dedup); this view just binds its editable draft and saves.
///
/// Lives in `GalavantCaptureUI` (the package's second UI module after `GalavantWeb`, per
/// ADR-0023) rather than the extension target, so both the share extension and the app's
/// capture-from-browser flow present the *same* confirm sheet. iOS-only SwiftUI modifiers
/// are `#if os(iOS)`-guarded so the module still compiles on the macOS `swift test` host,
/// like `GalavantWeb`.
public struct CaptureConfirmView: View {
  @Bindable var model: CaptureModel
  /// Called when the flow is done (after save, or on cancel) — the host tears down (the
  /// extension completes its request; the app dismisses the sheet).
  let onClose: () -> Void

  public init(model: CaptureModel, onClose: @escaping () -> Void) {
    self.model = model
    self.onClose = onClose
  }

  public var body: some View {
    NavigationStack {
      content
        .navigationTitle("Add to Galavant")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: onClose)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(model.existingMatch == nil ? "Save" : "Update") {
              Task { await model.save() }
            }
            .disabled(!isSavable)
          }
        }
    }
    .task { await model.prepare() }
    .onChange(of: model.phase) { _, phase in
      if phase == .saved {
        // Signal the (possibly running) app to re-read — its @FetchAll observation
        // can't see a separate process's write (the extension); in-app it's a no-op
        // beyond the observation it already drives.
        DatabaseChange.post()
        onClose()
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .preparing:
      ProgressView("Reading page…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    default:
      form
    }
  }

  private var form: some View {
    Form {
      if let existing = model.existingMatch {
        Section {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Already in your pool")
              Text(
                "Saving will update \(existingName(existing)) instead of adding a duplicate."
              )
              .font(.footnote)
              .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          }
        }
      }

      if !model.trips.isEmpty {
        Section("Trip") {
          Picker("Add to trip", selection: $model.selectedTripID) {
            ForEach(model.trips) { trip in
              Text(tripLabel(trip)).tag(Trip.ID?.some(trip.id))
            }
            Text("None").tag(Trip.ID?.none)
          }
        }
      }

      Section("Place") {
        TextField("Name", text: $model.draft.name)
        Picker("Kind", selection: $model.draft.kind) {
          Text("Unspecified").tag(IdeaKind?.none)
          ForEach(IdeaKind.allCases, id: \.self) { kind in
            Label(kind.label, systemImage: kind.systemImage).tag(IdeaKind?.some(kind))
          }
        }
      }

      Section("Location") {
        if let coordinate = draftCoordinate {
          // Keyed on the coordinate so picking a new location in search recenters.
          Map(
            initialPosition: .region(
              MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
          ) {
            Marker(model.draft.name.isEmpty ? "Location" : model.draft.name, coordinate: coordinate)
          }
          .frame(height: 160)
          .allowsHitTesting(false)
          .listRowInsets(EdgeInsets())
          .id("\(coordinate.latitude),\(coordinate.longitude)")
        }
        NavigationLink {
          LocationSearchView(model: model)
        } label: {
          Text(locationSummary)
            .foregroundStyle(hasLocation ? .primary : .secondary)
        }
        if hasLocation {
          Button("Clear location", role: .destructive) { model.clearLocation() }
        }
      }

      if !model.detectedEvaluations.isEmpty {
        Section {
          ForEach($model.detectedEvaluations) { $detected in
            VStack(alignment: .leading, spacing: 8) {
              Toggle(isOn: $detected.included) {
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(detected.sourceName)
                    if detected.confidence != .official {
                      Text(detected.confidence.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                  }
                  Spacer()
                  Text(detected.nativeDisplay).bold()
                }
              }
              if detected.included {
                ratingEditor($detected)
              }
            }
          }
        } header: {
          Text("Ratings")
        } footer: {
          Text("Tap to correct a misread rating before saving.")
        }
      }

      Section("Notes") {
        TextField("Notes", text: $model.draft.notes, axis: .vertical)
          .lineLimit(1...5)
      }

      if let phone = model.draft.phone, !phone.isEmpty {
        Section("Phone") {
          Text(phone).foregroundStyle(.secondary)
        }
      }

      if !model.draft.url.isEmpty {
        Section("Link") {
          Text(model.draft.url)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      if case let .failed(message) = model.phase {
        Section {
          Text(message).foregroundStyle(.red)
        }
      }
    }
  }

  /// Correct a misread rating before saving — a stepper for stars, a number field for
  /// a bounded score, a text field for everything else. Each edit regenerates the
  /// native value triad on the bound `DetectedEvaluation` (`correctStyle` helpers).
  @ViewBuilder
  private func ratingEditor(_ detected: Binding<DetectedEvaluation>) -> some View {
    switch detected.wrappedValue.correctionStyle {
    case .stars:
      Stepper(
        value: Binding(
          get: { detected.wrappedValue.starCount },
          set: { detected.wrappedValue.correctStars($0) }
        ),
        in: 0...detected.wrappedValue.starCap
      ) {
        Text("Stars: \(detected.wrappedValue.starCount)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    case .score:
      HStack {
        Text("Score").font(.subheadline).foregroundStyle(.secondary)
        Spacer()
        TextField(
          "Score",
          value: Binding(
            get: { detected.wrappedValue.scoreValue },
            set: { detected.wrappedValue.correctScore($0) }
          ),
          format: .number
        )
        .multilineTextAlignment(.trailing)
        #if os(iOS)
          .keyboardType(.decimalPad)
        #endif
      }
    case .text:
      TextField(
        "Value",
        text: Binding(
          get: { detected.wrappedValue.nativeDisplay },
          set: { detected.wrappedValue.correctText($0) }
        )
      )
      .font(.subheadline)
    }
  }

  private func tripLabel(_ trip: Trip) -> String {
    trip.name.isEmpty ? "Untitled trip" : trip.name
  }

  /// The existing idea's name for the supplement banner, quoted, or a neutral
  /// fallback when it's blank.
  private func existingName(_ idea: Idea) -> String {
    idea.name.isEmpty ? "the existing idea" : "“\(idea.name)”"
  }

  private var isSavable: Bool {
    !model.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && model.phase != .saving
  }

  private var hasLocation: Bool {
    model.draft.latitude != nil || model.draft.address != nil
  }

  /// The resolved coordinate for the map preview, when one is set.
  private var draftCoordinate: CLLocationCoordinate2D? {
    guard let lat = model.draft.latitude, let lon = model.draft.longitude else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
  }

  private var locationSummary: String {
    if let address = model.draft.address { return address }
    if let lat = model.draft.latitude, let lon = model.draft.longitude {
      return String(format: "%.4f, %.4f", lat, lon)
    }
    return "No location found — add it in the app"
  }
}
