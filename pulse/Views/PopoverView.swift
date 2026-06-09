import SwiftUI

struct PopoverView: View {
    @AppStorage("selectedTab") private var selectedTab = 0
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var agentUsageSettings: AgentUsageSettings

    private var availableTabs: [(title: String, tag: Int)] {
        var tabs: [(String, Int)] = [("Overview", 0), ("Processes", 1)]
        if agentUsageSettings.isEnabled {
            tabs.append(("Agent", 2))
        }
        return tabs
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(availableTabs, id: \.tag) { tab in
                        Text(tab.title).tag(tab.tag)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()
                    .background(Color.appDivider)

                ZStack {
                    OverviewView()
                        .opacity(selectedTab == 0 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 0)

                    ProcessListView()
                        .opacity(selectedTab == 1 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 1)

                    if agentUsageSettings.isEnabled {
                        AgentUsageView()
                            .opacity(selectedTab == 2 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: agentUsageSettings.isEnabled ? 460 : 300, minHeight: 360)
        .id(themeManager.currentTheme)
        .onChange(of: agentUsageSettings.isEnabled) { isEnabled in
            if isEnabled == false && selectedTab == 2 {
                selectedTab = 0
            }
            syncPanelTabSelection()
        }
        .onChange(of: selectedTab) { _ in
            syncPanelTabSelection()
        }
        .onAppear {
            if agentUsageSettings.isEnabled == false && selectedTab == 2 {
                selectedTab = 0
            }
            syncPanelTabSelection()
        }
    }

    private func syncPanelTabSelection() {
        NotificationCenter.default.post(name: .pulsePanelTabDidChange, object: selectedTab)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
