import AppKit
import Combine
import SwiftUI

private enum PanelMetrics {
    static let selectedTabDefaultsKey = "selectedTab"
    static let baseWidth: CGFloat = 300
    static let agentWidth: CGFloat = 460
    static let baseHeight: CGFloat = 420
    static let agentHeight: CGFloat = baseHeight * 2
    static let baseMinWidth: CGFloat = 280
    static let agentMinWidth: CGFloat = 420
    static let baseMinHeight: CGFloat = 320
    static let agentMinHeight: CGFloat = baseMinHeight * 2
}

enum AgentStatusPanelMetrics {
    static let width: CGFloat = 460
    static let height: CGFloat = 840
    static let minWidth: CGFloat = 360
    static let minHeight: CGFloat = 560
}

private enum SettingsWindowMetrics {
    static let defaultWidth: CGFloat = 800
    static let defaultHeight: CGFloat = 600
    static let minWidth: CGFloat = 520
    static let minHeight: CGFloat = 280
}

extension Notification.Name {
    static let pulsePanelTabDidChange = Notification.Name("pulsePanelTabDidChange")
    static let pulsePanelDidOpen = Notification.Name("pulsePanelDidOpen")
    static let pulseShowSessionManagementWindow = Notification.Name("pulseShowSessionManagementWindow")
    static let pulseSessionManagementWindowDidOpen = Notification.Name("pulseSessionManagementWindowDidOpen")
    static let pulseShowAgentUsageMappingWindow = Notification.Name("pulseShowAgentUsageMappingWindow")
}

private final class InputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func zoom(_ sender: Any?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let current = frame
        let target = NSRect(
            x: current.origin.x,
            y: screen.visibleFrame.maxY - current.height * 2,
            width: current.width * 1.5,
            height: current.height * 2
        )
        let isZoomed = abs(frame.width - target.width) < 2 && abs(frame.height - target.height) < 2
        if isZoomed {
            let agentEnabled = AgentUsageSettings.isEffectivelyEnabled(userDefaults: .standard)
            let selectedTab = UserDefaults.standard.integer(forKey: PanelMetrics.selectedTabDefaultsKey)
            let targetWidth = agentEnabled ? PanelMetrics.agentWidth : PanelMetrics.baseWidth
            let targetHeight = agentEnabled && selectedTab == 2 ? PanelMetrics.agentHeight : PanelMetrics.baseHeight
            setFrame(
                NSRect(
                    x: current.origin.x,
                    y: screen.visibleFrame.maxY - targetHeight,
                    width: targetWidth,
                    height: targetHeight
                ),
                display: true,
                animate: true
            )
        } else {
            setFrame(target, display: true, animate: true)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var agentStatusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: MenuBarStatusItemView.defaultWidth)
    private var panel: InputPanel?
    private var agentStatusPanel: InputPanel?
    private var eventMonitor: Any?
    private var agentStatusEventMonitor: Any?
    private var settingsWindow: NSWindow?
    private var sessionManagementWindow: NSWindow?
    private var agentUsageMappingWindow: NSWindow?
    private var hasPresentedSettingsWindow = false
    private var cancellables = Set<AnyCancellable>()
    private var menuBarStatusView: MenuBarStatusItemView?
    private let monitor = SystemMonitor()
    private let themeManager = ThemeManager()
    private let sessionManagerThemeManager = SessionManagerThemeManager()
    private let agentUsageSettings = AgentUsageSettings()
    private let agentUsageStore = AgentUsageStore()
    private let sessionManagementStore = SessionManagementStore()
    private let agentLightsSettings = AgentLightsSettings()
    private let agentStatusStore = AgentStatusStore(enabledAgents: AgentStatusAgent.allCases)
    private let agentStatusPanelSelection = AgentStatusPanelSelection()
    private let agentIntegrationManager = AgentIntegrationManager()
    private lazy var agentStatusServer = PulseAgentStatusServer(store: agentStatusStore)
    private lazy var updateManager = UpdateManager(client: LiveUpdateClient(repoOwner: "Re-Jacky", repoName: "pulse"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        agentUsageStore.setEnabledSources(agentUsageSettings.enabledSources)
        setupMainMenu()
        setupThemeObservation()
        setupFeatureObservation()
        setupPanelObservation()

        Task { @MainActor [weak self] in
            await self?.updateManager.checkForUpdates(userInitiated: true)
            self?.updateManager.startAutomaticChecks()
        }

        updateManager.performPostUpgradeTasks()

        setupStatusItem()
        setupAgentStatusItem()
        agentStatusServer.start()

        // Pre-build the panel so the first open is instant.
        panel = makePanel()
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "System Monitor")
        button.image?.isTemplate = true
        button.action = #selector(handleClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupAgentStatusItem() {
        agentStatusItem.isVisible = false

        guard let button = agentStatusItem.button else {
            return
        }

        button.image = nil
        button.action = nil
        button.target = nil
        button.sendAction(on: [])
        button.subviews.forEach { $0.removeFromSuperview() }

        let statusView = MenuBarStatusItemView(frame: button.bounds)
        statusView.autoresizingMask = [.width, .height]
        statusView.onLeftClickAgent = { [weak self] agent in
            DispatchQueue.main.async { [weak self] in
                self?.openAgentStatusPanel(for: agent)
            }
        }
        statusView.onRightClickAgent = { [weak self] agent in
            DispatchQueue.main.async { [weak self] in
                self?.openAgentStatusPanel(for: agent)
            }
        }
        statusView.onPreferredWidthChange = { [weak self, weak statusView] width in
            guard let self else { return }
            self.agentStatusItem.length = width
            statusView?.frame = self.agentStatusItem.button?.bounds ?? .zero
        }
        statusView.bind(to: agentStatusStore, settings: agentLightsSettings)

        button.addSubview(statusView)
        menuBarStatusView = statusView
        updateAgentStatusItemVisibility()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.title = "Pulse"
        appMenuItem.submenu = appMenu
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(closeItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    @objc private func togglePanel() {
        if let panel, panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        closeAgentStatusPanel()

        let p: InputPanel
        if let existing = panel {
            p = existing
        } else {
            p = makePanel()
            panel = p
        }

        if let button = statusItem.button,
           let screen = button.window?.screen ?? NSScreen.main {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero
            let x = screenRect.midX - p.frame.width / 2
            let y = screenRect.minY - p.frame.height - 4
            let clamped = max(screen.visibleFrame.minX, min(x, screen.visibleFrame.maxX - p.frame.width))
            p.setFrameOrigin(NSPoint(x: clamped, y: y))
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            if self.hasVisibleOwnedRegularWindow(excluding: self.panel) == false {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        NotificationCenter.default.post(name: .pulsePanelDidOpen, object: nil)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        if hasVisibleOwnedRegularWindow() == false {
            NSApp.setActivationPolicy(.accessory)
        }
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }

    @objc private func toggleAgentStatusPanel() {
        if let agentStatusPanel, agentStatusPanel.isVisible {
            closeAgentStatusPanel()
        } else {
            openAgentStatusPanel()
        }
    }

    private func openAgentStatusPanel(for agent: AgentStatusAgent) {
        agentStatusPanelSelection.selectedAgent = agent

        if let agentStatusPanel, agentStatusPanel.isVisible {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            agentStatusPanel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                if self.hasVisibleOwnedRegularWindow(excluding: self.agentStatusPanel) == false {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            return
        }

        openAgentStatusPanel()
    }

    private func openAgentStatusPanel() {
        closePanel()

        let p: InputPanel
        if let existing = agentStatusPanel {
            p = existing
        } else {
            p = makeAgentStatusPanel()
            agentStatusPanel = p
        }

        if let button = agentStatusItem.button,
           let screen = button.window?.screen ?? NSScreen.main {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero
            let x = screenRect.midX - p.frame.width / 2
            let y = screenRect.minY - p.frame.height - 4
            let clamped = max(screen.visibleFrame.minX, min(x, screen.visibleFrame.maxX - p.frame.width))
            p.setFrameOrigin(NSPoint(x: clamped, y: y))
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            if self.hasVisibleOwnedRegularWindow(excluding: self.agentStatusPanel) == false {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.installAgentStatusEventMonitor()
        }
    }

    private func closeAgentStatusPanel() {
        agentStatusPanel?.orderOut(nil)
        if hasVisibleOwnedRegularWindow() == false {
            NSApp.setActivationPolicy(.accessory)
        }
        if let monitor = agentStatusEventMonitor {
            NSEvent.removeMonitor(monitor)
            agentStatusEventMonitor = nil
        }
    }

    private func installAgentStatusEventMonitor() {
        if let monitor = agentStatusEventMonitor {
            NSEvent.removeMonitor(monitor)
            agentStatusEventMonitor = nil
        }

        agentStatusEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            if isPointInsideAgentStatusItem(mouseLocation) {
                return
            }
            self.closeAgentStatusPanel()
        }
    }

    private func isPointInsideAgentStatusItem(_ screenPoint: NSPoint) -> Bool {
        guard let button = agentStatusItem.button,
              let window = button.window else {
            return false
        }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(buttonRect)
        return screenRect.contains(screenPoint)
    }

    private func setupThemeObservation() {
        applyCurrentTheme()
        applySessionManagementTheme()

        themeManager.$currentTheme
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyCurrentTheme()
            }
            .store(in: &cancellables)

        sessionManagerThemeManager.$currentTheme
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applySessionManagementTheme()
            }
            .store(in: &cancellables)
    }

    private func setupFeatureObservation() {
        agentUsageSettings.$isEnabled
            .combineLatest(agentUsageSettings.$selectedSources)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                agentUsageStore.setEnabledSources(agentUsageSettings.enabledSources)
                updatePanelLayout(agentEnabled: agentUsageSettings.effectiveEnabled, selectedTab: currentSelectedTab, animated: true)
            }
            .store(in: &cancellables)

        agentLightsSettings.$isEnabled
            .combineLatest(agentLightsSettings.$selectedAgents)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateAgentStatusItemVisibility()
            }
            .store(in: &cancellables)
    }

    private func setupPanelObservation() {
        NotificationCenter.default.publisher(for: .pulsePanelTabDidChange)
            .compactMap { $0.object as? Int }
            .receive(on: RunLoop.main)
            .sink { [weak self] selectedTab in
                guard let self else { return }
                updatePanelLayout(agentEnabled: agentUsageSettings.effectiveEnabled, selectedTab: selectedTab, animated: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .pulseShowSessionManagementWindow)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.showSessionManagementWindow()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .pulseShowAgentUsageMappingWindow)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.showAgentUsageMappingWindow(notification)
            }
            .store(in: &cancellables)
    }

    private func applyCurrentTheme() {
        let appearance = themeManager.currentTheme.nsAppearance
        panel?.appearance = appearance
        panel?.contentViewController?.view.appearance = appearance
        panel?.contentView?.needsDisplay = true
        agentStatusPanel?.appearance = appearance
        agentStatusPanel?.contentViewController?.view.appearance = appearance
        agentStatusPanel?.contentView?.needsDisplay = true
        settingsWindow?.appearance = appearance
        settingsWindow?.contentViewController?.view.appearance = appearance
        settingsWindow?.contentView?.needsDisplay = true
        agentUsageMappingWindow?.appearance = appearance
        agentUsageMappingWindow?.contentViewController?.view.appearance = appearance
        agentUsageMappingWindow?.contentView?.needsDisplay = true
    }

    private func applySessionManagementTheme() {
        let appearance = sessionManagerThemeManager.currentTheme.nsAppearance
        sessionManagementWindow?.appearance = appearance
        sessionManagementWindow?.contentViewController?.view.appearance = appearance
        sessionManagementWindow?.contentView?.needsDisplay = true
    }

    private func makePanel() -> InputPanel {
        let metrics = panelMetrics(agentEnabled: agentUsageSettings.effectiveEnabled, selectedTab: currentSelectedTab)
        let p = InputPanel(
            contentRect: NSRect(x: 0, y: 0, width: metrics.width, height: metrics.height),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.minSize = NSSize(width: metrics.minWidth, height: metrics.minHeight)
        p.appearance = themeManager.currentTheme.nsAppearance
        p.backgroundColor = .clear
        p.isOpaque = false

        let vc = NSHostingController(
            rootView: PopoverView()
                .environmentObject(monitor)
                .environmentObject(themeManager)
                .environmentObject(agentUsageSettings)
                .environmentObject(agentUsageStore)
                .environmentObject(updateManager)
        )
        vc.view.appearance = themeManager.currentTheme.nsAppearance
        p.contentViewController = vc

        if let contentView = p.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 12
            contentView.layer?.masksToBounds = true
        }
        return p
    }

    private var currentSelectedTab: Int {
        UserDefaults.standard.integer(forKey: PanelMetrics.selectedTabDefaultsKey)
    }

    private func panelMetrics(agentEnabled: Bool, selectedTab: Int) -> (width: CGFloat, height: CGFloat, minWidth: CGFloat, minHeight: CGFloat) {
        let width = agentEnabled ? PanelMetrics.agentWidth : PanelMetrics.baseWidth
        let minWidth = agentEnabled ? PanelMetrics.agentMinWidth : PanelMetrics.baseMinWidth
        let isAgentTabActive = agentEnabled && selectedTab == 1
        let height = isAgentTabActive ? PanelMetrics.agentHeight : PanelMetrics.baseHeight
        let minHeight = isAgentTabActive ? PanelMetrics.agentMinHeight : PanelMetrics.baseMinHeight
        return (width, height, minWidth, minHeight)
    }

    private func updatePanelLayout(agentEnabled: Bool, selectedTab: Int, animated: Bool) {
        guard let panel else { return }

        let metrics = panelMetrics(agentEnabled: agentEnabled, selectedTab: selectedTab)
        var frame = panel.frame
        guard abs(frame.width - metrics.width) > 1 || abs(frame.height - metrics.height) > 1 else {
            panel.minSize = NSSize(width: metrics.minWidth, height: metrics.minHeight)
            return
        }

        let topEdge = frame.maxY
        let midX = frame.midX
        frame.size.width = metrics.width
        frame.size.height = metrics.height
        frame.origin.x = midX - metrics.width / 2
        frame.origin.y = topEdge - metrics.height
        panel.setFrame(frame, display: true, animate: animated)
        panel.minSize = NSSize(width: metrics.minWidth, height: metrics.minHeight)
    }

    private func makeAgentStatusPanel() -> InputPanel {
        let panel = InputPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: AgentStatusPanelMetrics.width,
                height: AgentStatusPanelMetrics.height
            ),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: AgentStatusPanelMetrics.minWidth, height: AgentStatusPanelMetrics.minHeight)
        panel.appearance = themeManager.currentTheme.nsAppearance
        panel.backgroundColor = .clear
        panel.isOpaque = false

        let controller = makeAgentStatusHostingController()
        controller.view.appearance = themeManager.currentTheme.nsAppearance
        panel.contentViewController = controller

        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 12
            contentView.layer?.masksToBounds = true
        }

        return panel
    }

    private func makeAgentStatusHostingController() -> NSHostingController<some View> {
        NSHostingController(
            rootView: ZStack {
                VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
                    .ignoresSafeArea()
                AgentStatusManagementView()
                    .environment(agentStatusPanelSelection)
                    .environmentObject(agentStatusStore)
                    .environmentObject(agentIntegrationManager)
            }
            .id(themeManager.currentTheme)
        )
    }

    private func updateAgentStatusItemVisibility() {
        let shouldShow = agentLightsSettings.isEnabled && agentLightsSettings.selectedAgents.isEmpty == false
        let enabledAgents = Set(agentLightsSettings.enabledAgents)
        agentStatusItem.isVisible = shouldShow
        if enabledAgents.contains(agentStatusPanelSelection.selectedAgent) == false {
            closeAgentStatusPanel()
        } else if shouldShow == false {
            closeAgentStatusPanel()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let openTitle = (panel?.isVisible == true) ? "Close" : "Open"
        let openItem = NSMenuItem(title: openTitle, action: #selector(togglePanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showSettings() {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        window.appearance = themeManager.currentTheme.nsAppearance
        window.contentViewController?.view.appearance = themeManager.currentTheme.nsAppearance
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if !window.isVisible {
            if hasPresentedSettingsWindow == false {
                window.setFrame(
                    NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: SettingsWindowMetrics.defaultWidth, height: SettingsWindowMetrics.defaultHeight),
                    display: false
                )
            }
            window.center()
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.arrangeInFront(nil)
        hasPresentedSettingsWindow = true
    }

    @objc private func showSessionManagementWindow() {
        closePanel()
        closeAgentStatusPanel()

        let window = sessionManagementWindow ?? makeSessionManagementWindow()
        sessionManagementWindow = window
        window.appearance = sessionManagerThemeManager.currentTheme.nsAppearance
        window.contentViewController?.view.appearance = sessionManagerThemeManager.currentTheme.nsAppearance
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.center()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.arrangeInFront(nil)
        NotificationCenter.default.post(name: .pulseSessionManagementWindowDidOpen, object: nil)
    }

    private func showAgentUsageMappingWindow(_ notification: Notification) {
        guard let providerCandidates = notification.userInfo?[AgentUsageMappingWindowNotificationKey.providerCandidates] as? [AgentUsageProviderMappingCandidate],
              let modelCandidates = notification.userInfo?[AgentUsageMappingWindowNotificationKey.modelCandidates] as? [AgentUsageModelMappingCandidate] else {
            return
        }

        closePanel()
        closeAgentStatusPanel()

        let window = agentUsageMappingWindow ?? makeAgentUsageMappingWindow()
        agentUsageMappingWindow = window
        window.appearance = themeManager.currentTheme.nsAppearance
        window.contentViewController = makeAgentUsageMappingController(
            providerCandidates: providerCandidates,
            modelCandidates: modelCandidates
        )
        window.contentViewController?.view.appearance = themeManager.currentTheme.nsAppearance
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if window.isVisible == false {
            window.center()
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.arrangeInFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsWindowMetrics.defaultWidth, height: SettingsWindowMetrics.defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: SettingsWindowMetrics.minWidth, height: SettingsWindowMetrics.minHeight)
        window.appearance = themeManager.currentTheme.nsAppearance
        window.isExcludedFromWindowsMenu = false
        window.delegate = self

        let controller = NSHostingController(
            rootView: SettingsView()
                .environmentObject(themeManager)
                .environmentObject(agentUsageSettings)
                .environmentObject(agentLightsSettings)
                .environmentObject(agentStatusStore)
                .environmentObject(updateManager)
        )
        controller.view.appearance = themeManager.currentTheme.nsAppearance
        window.contentViewController = controller
        return window
    }

    private func makeSessionManagementWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1770, height: 1280),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Manage Sessions"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1240, height: 720)
        window.appearance = sessionManagerThemeManager.currentTheme.nsAppearance
        window.isExcludedFromWindowsMenu = false
        window.delegate = self

        let controller = NSHostingController(
            rootView: SessionManagementWindowView()
                .environmentObject(sessionManagementStore)
                .environmentObject(sessionManagerThemeManager)
                .environmentObject(agentUsageSettings)
        )
        controller.view.appearance = sessionManagerThemeManager.currentTheme.nsAppearance
        window.contentViewController = controller
        return window
    }

    private func makeAgentUsageMappingWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 960),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "All View Mapping"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 640)
        window.appearance = themeManager.currentTheme.nsAppearance
        window.isExcludedFromWindowsMenu = false
        window.delegate = self
        return window
    }

    private func makeAgentUsageMappingController(
        providerCandidates: [AgentUsageProviderMappingCandidate],
        modelCandidates: [AgentUsageModelMappingCandidate]
    ) -> NSHostingController<AgentUsageMappingPanel> {
        let controller = NSHostingController(
            rootView: AgentUsageMappingPanel(
                providerCandidates: providerCandidates,
                modelCandidates: modelCandidates,
                mappingStore: agentUsageStore.mappingStore
            )
        )
        controller.view.appearance = themeManager.currentTheme.nsAppearance
        return controller
    }

    private func hasVisibleOwnedRegularWindow(excluding excludedWindow: NSWindow? = nil) -> Bool {
        let ownedWindows: [NSWindow?] = [settingsWindow, sessionManagementWindow, agentUsageMappingWindow]
        return ownedWindows.contains { window in
            guard let window else { return false }
            return window !== excludedWindow && window.isVisible
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow || window === sessionManagementWindow || window === agentUsageMappingWindow else { return }
        if hasVisibleOwnedRegularWindow(excluding: window) == false {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
