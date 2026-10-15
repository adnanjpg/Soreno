import SwiftUI
import AppKit

@MainActor
final class DesktopAppWindowManager {
    static let shared = DesktopAppWindowManager()

    private var windowController: NSWindowController?

    private init() {}

    func show(appState: AppState) {
        let windowController = ensureWindowController(appState: appState)
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureWindowController(appState: AppState) -> NSWindowController {
        if let existing = windowController,
           let hostingController = existing.contentViewController as? NSHostingController<AnyView> {
            hostingController.rootView = AnyView(SettingsView().environmentObject(appState))
            return existing
        }

        let rootView = AnyView(SettingsView().environmentObject(appState))
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Soreno"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 560))
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        self.windowController = controller
        return controller
    }
}
