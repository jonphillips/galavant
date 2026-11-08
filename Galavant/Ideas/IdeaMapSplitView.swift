import GalavantSchema
import SwiftUI

private enum IdeaMapPanelMetrics {
  // The approved dossier-panel brief sets the panel width, edge inset, and radius.
  static let width: CGFloat = 360
  static let inset: CGFloat = 12
  static let cornerRadius: CGFloat = 16

  // Keep framing out from under the panel: width plus the trailing edge inset.
  static var mapTrailingReserve: CGFloat { width + inset }
}

struct IdeaMapSplitView<Column: View, Map: View>: View {
  let ideaID: Idea.ID?
  let onClose: () -> Void
  @ViewBuilder let column: () -> Column
  @ViewBuilder let map: () -> Map

  var body: some View {
    HStack(spacing: 0) {
      column().frame(maxWidth: 420)
      Divider()
      mapWithDossier
    }
  }

  private var mapWithDossier: some View {
    ZStack(alignment: .trailing) {
      map()
        .safeAreaPadding(.trailing, ideaID == nil ? 0 : IdeaMapPanelMetrics.mapTrailingReserve)

      if let ideaID {
        IdeaDetailView(
          ideaID: ideaID,
          canEdit: true,
          chrome: .panel(onClose: onClose)
        )
        .frame(width: IdeaMapPanelMetrics.width)
        .background(.background, in: RoundedRectangle(cornerRadius: IdeaMapPanelMetrics.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: IdeaMapPanelMetrics.cornerRadius))
        .shadow(radius: IdeaMapPanelMetrics.cornerRadius)
        .padding(IdeaMapPanelMetrics.inset)
        .id(ideaID)
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(.default, value: ideaID != nil)
  }
}
