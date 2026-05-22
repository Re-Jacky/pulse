import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private let monitor = SystemMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "System Monitor")
            button.image?.isTemplate = true
            button.action = #selector(togglePanel)
            button.target = self
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

        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
            styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.isMovableByWindowBackground = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.minSize = NSSize(width: 280, height: 320)

        let vc = NSHostingController(rootView: PopoverView().environmentObject(monitor))
        vc.view.appearance = NSAppearance(named: .darkAqua)
        p.contentViewController = vc
        return p
    }
}
