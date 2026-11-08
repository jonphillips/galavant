import GalavantSchema
import SwiftUI

private enum IdeaMapPanelMetrics {
  // The approved dossier-panel brief sets the panel width, edge inset, and radius.
  static let width: CGFloat = 360
  static let inset: CGFloat = 12
  static let cornerRadius: CGFloat = 16
  // The shadow uses the approved corner-radius scale as its visual depth.
  static let shadowRadius: CGFloat = 16

  // Keep framing out from under the panel: width plus the trailing edge inset.
  static var mapTrailingReserve: CGFloat { width + inset }
}

struct IdeaMapSplitView<Column: View, Map: View, Accessory: View>: View {
  let ideaID: Idea.ID?
  let onClose: () -> Void
  @ViewBuilder let column: () -> Column
  @ViewBuilder let map: () -> Map
  @ViewBuilder let dossierAccessory: () -> Accessory

  init(
    ideaID: Idea.ID?,
    onClose: @escaping () -> Void,
    @ViewBuilder column: @escaping () -> Column,
    @ViewBuilder map: @escaping () -> Map,
    @ViewBuilder dossierAccessory: @escaping () -> Accessory = { EmptyView() }
  ) {
    self.ideaID = ideaID
    self.onClose = onClose
    self.column = column
    self.map = map
    self.dossierAccessory = dossierAccessory
  }

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
        .safeAreaInset(edge: .bottom) { dossierAccessory() }
        .frame(width: IdeaMapPanelMetrics.width)
        .background(.background, in: RoundedRectangle(cornerRadius: IdeaMapPanelMetrics.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: IdeaMapPanelMetrics.cornerRadius))
        .shadow(radius: IdeaMapPanelMetrics.shadowRadius)
        .padding(IdeaMapPanelMetrics.inset)
        .id(ideaID)
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(.default, value: ideaID != nil)
  }
}
