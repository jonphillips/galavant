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
  @State private var pendingIdentity: Planner?

  var body: some View {
    List {
      Section {
        ForEach(model.planners) { planner in
          row(planner)
        }
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            "Rename or remove the people who vote on ideas. Deleting a planner also "
              + "removes the ratings they left — use it to clear out stale duplicates.")
          if !model.hasCurrentPlanner {
            Text("Swipe left on your name and tap This is me.")
          }
        }
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
    .alert(
      "Use this device as \(pendingIdentity?.displayName ?? "planner")?",
      isPresented: Binding(get: { pendingIdentity != nil }, set: { if !$0 { pendingIdentity = nil } })
    ) {
      Button("Use This Planner") {
        if let planner = pendingIdentity { model.setCurrentPlanner(planner) }
        pendingIdentity = nil
      }
      Button("Cancel", role: .cancel) { pendingIdentity = nil }
    } message: {
      if let planner = pendingIdentity {
        Text("Votes and your taste overlay will be \(planner.displayName)'s on this device.")
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
        Button {
          if model.currentPlannerID == nil {
            model.setCurrentPlanner(planner)
          } else {
            pendingIdentity = planner
          }
        } label: {
          Label("This is me", systemImage: "person.crop.circle")
        }
        .tint(.accentColor)

        Button(role: .destructive) {
          pendingDelete = planner
        } label: {
          Icon.delete.label("Delete")
        }
      }
    }
  }
}
