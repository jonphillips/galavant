import GalavantPlaces
import GalavantSchema
import MapKit
import SwiftUI

/// The confirm-and-tweak sheet shown when you share a page (Jon's choice: vet
/// captures at the source). The `CaptureModel` does the parse + Apple Maps match;
/// this view just binds its editable draft and saves. A focused form — not the
/// app's full `IdeaFormView` (that lives in the app target, unreachable here).
struct CaptureConfirmView: View {
  @Bindable var model: CaptureModel
  /// Called to tear the extension down (after save, or on cancel).
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Add to Galavant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: onClose)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { Task { await model.save() } }
              .disabled(!isSavable)
          }
        }
    }
    .task { await model.prepare() }
    .onChange(of: model.phase) { _, phase in
      if phase == .saved {
        // Signal the (possibly running) app to re-read — its @FetchAll observation
        // can't see this separate process's write.
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

  private func tripLabel(_ trip: Trip) -> String {
    trip.name.isEmpty ? "Untitled trip" : trip.name
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
