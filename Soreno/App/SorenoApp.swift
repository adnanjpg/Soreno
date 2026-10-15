import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Local builds should be visible while we iterate on desktop UI.
        if ProductFlags.isLocalBuild {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@main
struct SorenoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    private var menuBarTemplateImage: NSImage? {
        if let image = NSImage(named: "MenuBarIconTemplate") {
            image.isTemplate = true
            return image
        }

        guard let url = Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.isTemplate = true
        return image
    }

    private var menuBarIconOpacity: Double {
        appState.isModelLoading || !appState.isModelLoaded ? 0.32 : 1.0
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            if let image = menuBarTemplateImage {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .opacity(menuBarIconOpacity)
                    .animation(.easeInOut(duration: 0.18), value: menuBarIconOpacity)
            } else {
                SorenoMenuBarLogo()
                    .opacity(menuBarIconOpacity)
                    .animation(.easeInOut(duration: 0.18), value: menuBarIconOpacity)
            }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandMenu("Soreno") {
                Button("Read Selected Text") {
                    appState.readSelectedTextAloud()
                }
                .disabled(appState.isInitializingUI)
                .keyboardShortcut("r", modifiers: [.command, .option])

                Button("Read Clipboard") {
                    appState.readClipboardAloud()
                }
                .disabled(appState.isInitializingUI)

                Button(appState.isReadAloudPaused ? "Resume Reading" : "Pause Reading") {
                    appState.toggleReadAloudPause()
                }
                .disabled(!appState.isReadAloudActive || appState.isInitializingUI)

                Button("Stop Reading") {
                    appState.stopReadAloud()
                }
                .disabled(appState.isInitializingUI)
                .keyboardShortcut(".", modifiers: [.command, .option])

                Divider()

                Button("Open Settings…") {
                    DesktopAppWindowManager.shared.show(appState: appState)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}
