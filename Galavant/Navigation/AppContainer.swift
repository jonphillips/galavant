import SwiftUI

/// The adaptive navigation shell: a tab bar on iPhone, a sidebar + detail split
/// on iPad and Mac. Each section gets its own navigation stack.
struct AppContainer: View {
  @State private var selection: AppScreen? = .ideas
  @Environment(\.prefersTabNavigation) private var prefersTabNavigation

  var body: some View {
    if prefersTabNavigation {
      TabView(selection: $selection) {
        ForEach(AppScreen.allCases) { screen in
          NavigationStack {
            screen.destination
          }
          .tag(screen as AppScreen?)
          .tabItem { screen.label }
        }
      }
    } else {
      NavigationSplitView {
        List(AppScreen.allCases, selection: $selection) { screen in
          screen.label
        }
        .navigationTitle("Galavant")
      } detail: {
        NavigationStack {
          if let selection {
            selection.destination
          } else {
            ContentUnavailableView(
              "Pick a section",
              systemImage: "sidebar.left"
            )
          }
        }
      }
    }
  }
}
