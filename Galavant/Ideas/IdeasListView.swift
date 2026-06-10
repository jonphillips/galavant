import Dependencies
import GalavantSchema
import SQLiteData
import SwiftUI
import SwiftUINavigation

struct IdeasListView: View {
  @State private var model = IdeasListModel()

  var body: some View {
    List {
      ForEach(model.ideas) { idea in
        Button {
          model.ideaTapped(idea)
        } label: {
          VStack(alignment: .leading) {
            Text(idea.name)
            if let regionName = idea.regionName, !regionName.isEmpty {
              Text(regionName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
        }
        .foregroundStyle(.primary)
      }
      .onDelete { model.deleteIdeas(at: $0) }
    }
    .navigationTitle("Ideas")
    .overlay {
      if model.ideas.isEmpty {
        ContentUnavailableView(
          "No ideas yet",
          systemImage: "lightbulb",
          description: Text("Tap + to capture your first travel idea.")
        )
      }
    }
    .toolbar {
      Button {
        model.addIdeaButtonTapped()
      } label: {
        Label("Add Idea", systemImage: "plus")
      }
    }
    .sheet(item: $model.destination.form, id: \.id) { draft in
      IdeaFormView(draft: draft)
    }
  }
}

#Preview {
  let _ = prepareDependencies {
    try! $0.bootstrapDatabase()
  }
  NavigationStack {
    IdeasListView()
  }
}
