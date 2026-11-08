import GalavantSchema
import SwiftUI

struct IdeaMapSplitView<Column: View, Map: View>: View {
  let ideaID: Idea.ID?
  let onBack: () -> Void
  @ViewBuilder let column: () -> Column
  @ViewBuilder let map: () -> Map

  var body: some View {
    HStack(spacing: 0) {
      if let ideaID {
        IdeaDetailView(ideaID: ideaID, canEdit: true, onBack: onBack)
          .frame(maxWidth: 420)
          .id(ideaID)
      } else {
        column().frame(maxWidth: 420)
      }
      Divider()
      map()
    }
  }
}
