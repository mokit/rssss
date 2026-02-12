import SwiftUI
import CoreData
import AppKit

struct SidebarPaneView: View {
    @Binding var selection: NSManagedObjectID?
    let feeds: [Feed]
    let unreadCounts: [NSManagedObjectID: Int]
    let onDelete: (Feed) -> Void
    let onAddFeed: () -> Void
    let onAddOPML: () -> Void

    static var sidebarMaterial: NSVisualEffectView.Material { .sidebar }
    static let sidebarOpacity: CGFloat = 0.96
    static var blurOverlayMaterial: NSVisualEffectView.Material { .underWindowBackground }
    static let blurOverlayOpacity: CGFloat = 0.34

    var body: some View {
        ZStack(alignment: .topLeading) {
            SidebarMaterialBackground(
                material: SidebarPaneView.sidebarMaterial,
                opacity: SidebarPaneView.sidebarOpacity
            )
                .ignoresSafeArea(.container, edges: .top)
            SidebarMaterialBackground(
                material: SidebarPaneView.blurOverlayMaterial,
                opacity: SidebarPaneView.blurOverlayOpacity
            )
                .ignoresSafeArea(.container, edges: .top)

            FeedSidebarView(
                selection: $selection,
                feeds: feeds,
                unreadCounts: unreadCounts,
                onDelete: onDelete,
                onAddFeed: onAddFeed,
                onAddOPML: onAddOPML
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SidebarMaterialBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let opacity: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        view.alphaValue = opacity
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.alphaValue = opacity
    }
}
