import GalavantSchema
import SwiftUI

/// Edits the shared household taste profile and the current planner's overlay
/// (ADR-0015 §3). The shared profile is surfaced first; the per-planner overlay
/// lets each person annotate their own skew on top of it.
///
/// Entry point is a stub for now — wired into the settings/"You" area once that
/// surface exists (BACKLOG). Both fields feed every model call through the
/// `ModelClient` boundary (ADR-0014).
struct TravelProfileEditView: View {
  @State private var model: TravelProfileEditModel
  @Environment(\.dismiss) private var dismiss

  init(travelPartyID: TravelParty.ID, plannerID: Planner.ID? = nil) {
    _model = State(initialValue: TravelProfileEditModel(
      travelPartyID: travelPartyID, plannerID: plannerID))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextEditor(text: $model.sharedDraft)
            .frame(minHeight: 100)
        } header: {
          Text("Household taste")
        } footer: {
          Text(
            "Shared by everyone on the trip. Describe the travel style you both care "
              + "about: luxury vs. value, pace, cuisine priorities, comfort level."
          )
        }

        if model.plannerID != nil {
          Section {
            TextEditor(text: $model.overlayDraft)
              .frame(minHeight: 80)
          } header: {
            Text("Your overlay")
          } footer: {
            Text(
              "Your personal skew on top of the shared profile. Leave blank to inherit "
                + "the household profile only."
            )
          }
        }
      }
      .navigationTitle("Taste Profile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            model.saveButtonTapped()
            dismiss()
          }
        }
      }
    }
    .task { await model.load() }
  }
}
