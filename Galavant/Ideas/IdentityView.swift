import GalavantSchema
import SwiftUI

struct IdentityView: View {
  let model: IdeasListModel
  @State private var name = ""
  @State private var creatingNew = false

  private var showNameField: Bool {
    model.planners.isEmpty || creatingNew
  }

  var body: some View {
    NavigationStack {
      Form {
        if showNameField {
          Section {
            TextField("Your name", text: $name)
          } header: {
            Text("Who's planning?")
          } footer: {
            Text("Your ratings and notes are labeled with this name so you and your travel party can tell them apart.")
          }
        } else {
          Section {
            ForEach(model.planners) { planner in
              Button {
                model.selectPlanner(planner)
              } label: {
                HStack {
                  Text(planner.displayName).foregroundStyle(.primary)
                  Spacer()
                  Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
              }
            }
            Button("Someone new…") { creatingNew = true }
          } header: {
            Text("Who are you?")
          } footer: {
            Text("Pick yourself so your ratings show up under your name. This only sets who you are on this device.")
          }
        }
      }
      .navigationTitle("Welcome to Galavant")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if showNameField {
          ToolbarItem(placement: .confirmationAction) {
            Button("Continue") { model.createPlanner(named: name) }
              .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
          }
          if creatingNew {
            ToolbarItem(placement: .cancellationAction) {
              Button("Back") { creatingNew = false }
            }
          }
        }
      }
    }
  }
}
