import AppKit
import Combine
import SwiftUI

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
            setFrame(NSRect(x: current.origin.x, y: screen.visibleFrame.maxY - 420, width: 300, height: 420), display: true, animate: true)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupThemeObservation()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "System Monitor")
            button.image?.isTemplate = true
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
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
        let p = makePanel()
        panel = p

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
            NSApp.setActivationPolicy(.accessory)
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
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
        let p = InputPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
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
        p.minSize = NSSize(width: 280, height: 320)
        p.appearance = themeManager.currentTheme.nsAppearance
        p.backgroundColor = .clear
        p.isOpaque = false

        let vc = NSHostingController(
            rootView: PopoverView()
                .environmentObject(monitor)
                .environmentObject(themeManager)
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
