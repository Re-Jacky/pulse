import SwiftUI

struct SessionManagementWindowView: View {
    @EnvironmentObject private var store: SessionManagementStore

    var body: some View {
        HSplitView {
            SessionListSidebarView()
                .frame(minWidth: 280, idealWidth: 340, maxHeight: .infinity)

            SessionTranscriptDetailView()
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            store.refreshIfNeeded()
        }
    }
}
