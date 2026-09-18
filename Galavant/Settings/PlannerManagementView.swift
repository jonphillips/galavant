import GalavantSchema
import SwiftUI

/// Settings ▸ Planners: the travel party's voters, with rename + delete so stale
/// or duplicate planner rows can be pruned (dogfood — the extra voters cluttering
/// the his/hers row). This device's own planner is shown but never deletable
/// here. No `NavigationStack` of its own — it drops into the Settings stack.
struct PlannerManagementView: View {
  @State private var model = PlannerManagementModel()
  @State private var renaming: Planner?
  @State private var nameDraft = ""
  @State private var pendingDelete: Planner?

  var body: some View {
    List {
      Section {
        ForEach(model.planners) { planner in
          row(planner)
        }
      } footer: {
        Text(
          "Rename or remove the people who vote on ideas. Deleting a planner also "
            + "removes the ratings they left — use it to clear out stale duplicates.")
      }
    }
    .navigationTitle("Planners")
    .overlay {
      if model.planners.isEmpty {
        ContentUnavailableView(
          "No planners yet",
          systemImage: "person.2",
          description: Text("Rate an idea to create your planner."))
      }
    }
    .alert(
      "Rename planner",
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField("Name", text: $nameDraft)
      Button("Save") {
        if let planner = renaming { model.rename(planner, to: nameDraft) }
        renaming = nil
      }
      Button("Cancel", role: .cancel) { renaming = nil }
    }
    .alert(
      "Delete planner?",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    ) {
      Button("Delete", role: .destructive) {
        if let planner = pendingDelete { model.delete(planner) }
        pendingDelete = nil
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: {
      if let planner = pendingDelete {
        Text(
          "\(planner.displayName.isEmpty ? "This planner" : planner.displayName) and the "
            + "^[\(model.voteCount(for: planner)) rating](inflect: true) they left will be removed.")
      }
    }
  }

  private func row(_ planner: Planner) -> some View {
    let isMe = planner.id == model.currentPlannerID
    return HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(planner.displayName.isEmpty ? "Unnamed planner" : planner.displayName)
        Text("^[\(model.voteCount(for: planner)) vote](inflect: true)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if isMe {
        Text("This device")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      nameDraft = planner.displayName
      renaming = planner
    }
    .swipeActions {
      if !isMe {
        Button(role: .destructive) {
          pendingDelete = planner
        } label: {
          Icon.delete.label("Delete")
        }
      }
    }
  }
}
