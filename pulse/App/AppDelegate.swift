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

extension Notification.Name {
    static let pulsePanelTabDidChange = Notification.Name("pulsePanelTabDidChange")
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
            let agentEnabled = UserDefaults.standard.object(forKey: AgentUsageSettings.userDefaultsKey) as? Bool == true
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: InputPanel?
    private var eventMonitor: Any?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let monitor = SystemMonitor()
    private let themeManager = ThemeManager()
    private let agentUsageSettings = AgentUsageSettings()
    private let agentUsageStore = AgentUsageStore()
    private lazy var updateManager = UpdateManager(client: LiveUpdateClient(repoOwner: "Re-Jacky", repoName: "pulse"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupThemeObservation()
        setupFeatureObservation()
        setupPanelObservation()

        Task { @MainActor [weak self] in
            await self?.updateManager.checkForUpdates(userInitiated: true)
        }

        updateManager.performPostUpgradeTasks()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "System Monitor")
            button.image?.isTemplate = true
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Pre-build the panel so the first open is instant.
        panel = makePanel()
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
            if self.settingsWindow?.isVisible != true {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        if settingsWindow?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }

    private func setupThemeObservation() {
        applyCurrentTheme()

        themeManager.$currentTheme
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyCurrentTheme()
            }
            .store(in: &cancellables)
    }

    private func setupFeatureObservation() {
        agentUsageSettings.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.updatePanelLayout(agentEnabled: isEnabled, selectedTab: self?.currentSelectedTab ?? 0, animated: true)
            }
            .store(in: &cancellables)
    }

    private func setupPanelObservation() {
        NotificationCenter.default.publisher(for: .pulsePanelTabDidChange)
            .compactMap { $0.object as? Int }
            .receive(on: RunLoop.main)
            .sink { [weak self] selectedTab in
                guard let self else { return }
                updatePanelLayout(agentEnabled: agentUsageSettings.isEnabled, selectedTab: selectedTab, animated: true)
            }
            .store(in: &cancellables)
    }

    private func applyCurrentTheme() {
        let appearance = themeManager.currentTheme.nsAppearance
        panel?.appearance = appearance
        panel?.contentViewController?.view.appearance = appearance
        panel?.contentView?.needsDisplay = true
        settingsWindow?.appearance = appearance
        settingsWindow?.contentViewController?.view.appearance = appearance
        settingsWindow?.contentView?.needsDisplay = true
    }

    private func makePanel() -> InputPanel {
        let metrics = panelMetrics(agentEnabled: agentUsageSettings.isEnabled, selectedTab: currentSelectedTab)
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
        let isAgentTabActive = agentEnabled && selectedTab == 2
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
            window.center()
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.arrangeInFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 280)
        window.appearance = themeManager.currentTheme.nsAppearance
        window.isExcludedFromWindowsMenu = false
        window.delegate = self

        let controller = NSHostingController(
            rootView: SettingsView()
                .environmentObject(themeManager)
                .environmentObject(agentUsageSettings)
                .environmentObject(updateManager)
        )
        controller.view.appearance = themeManager.currentTheme.nsAppearance
        window.contentViewController = controller
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        if panel?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
