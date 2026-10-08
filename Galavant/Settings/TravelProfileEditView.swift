import GalavantSchema
import SwiftUI

/// Edits the shared household taste profile and the current planner's overlay
/// (ADR-0015 §3). Settings → Library presents this editor; briefs and chat read
/// the profile.
struct TravelProfileEditView: View {
  @State private var model: TravelProfileEditModel
  @Environment(\.dismiss) private var dismiss

  init(travelPartyID: TravelParty.ID) {
    _model = State(initialValue: TravelProfileEditModel(travelPartyID: travelPartyID))
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

        Section {
          if model.canEditOverlay {
            TextEditor(text: $model.overlayDraft)
              .frame(minHeight: 80)
          } else {
            Text(
              "Choose who you are on this device to add your own taste."
            )
            NavigationLink {
              PlannerManagementView()
            } label: {
              Label("Choose Who You Are", systemImage: "person.crop.circle")
            }
          }
        } header: {
          Text("Your overlay")
        } footer: {
          if model.canEditOverlay {
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
    .task(id: model.plannerID) { await model.load() }
  }
}
