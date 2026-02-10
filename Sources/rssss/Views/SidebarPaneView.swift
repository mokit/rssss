import SwiftUI
import CoreData
import AppKit

struct SidebarPaneView: View {
    @Binding var selection: NSManagedObjectID?
    let feeds: [Feed]
    let unreadCounts: [NSManagedObjectID: Int]
    let onDelete: (Feed) -> Void
    let onAdd: () -> Void

    static var sidebarMaterial: NSVisualEffectView.Material { .sidebar }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SidebarMaterialBackground(material: SidebarPaneView.sidebarMaterial)
                .ignoresSafeArea(.container, edges: .top)

            FeedSidebarView(
                selection: $selection,
                feeds: feeds,
                unreadCounts: unreadCounts,
                onDelete: onDelete,
                onAdd: onAdd
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SidebarMaterialBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
