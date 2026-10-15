import Cocoa
import Carbon

/// Monitors keyboard for the configured push-to-talk hotkey.
/// Supports Globe (fn), modifier-only keys (Right ⌘, etc.), and key combos (F5, ⌥Space, etc.).
/// Uses CGEvent tap with .listenOnly (needs Input Monitoring permission).
final class GlobeKeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    var onReadAloudTrigger: (() -> Void)?
    var onExplainHoveredTrigger: (() -> Void)?

    /// Callback for hotkey recording mode — receives the captured Hotkey, then recording stops.
    var onHotkeyRecorded: ((AppConfig.Hotkey) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var keyDown = false

    /// The hotkey to listen for
    var hotkey: AppConfig.Hotkey = .globe

    /// When true, the next key event is captured as a new hotkey instead of triggering recording.
    var isRecordingHotkey = false

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        // Request Input Monitoring permission
        if !CGPreflightListenEventAccess() {
            sorenoLog("Input Monitoring not granted, requesting...")
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let keyWindow = NSApp.keyWindow {
                    keyWindow.makeKeyAndOrderFront(nil)
                } else if let anyWindow = NSApp.windows.first(where: { $0.isVisible }) {
                    anyWindow.makeKeyAndOrderFront(nil)
                }
                CGRequestListenEventAccess()
            }
        } else {
            sorenoLog("Input Monitoring already granted!")
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Listen for flagsChanged (modifiers) and keyDown (regular keys)
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
                                   | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<GlobeKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // Re-enable tap if it gets disabled
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                let flags = event.flags
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

                // Global read-aloud shortcut: ⌥⌘R
                if type == .keyDown,
                   keyCode == 15,
                   event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    let requiredMods: CGEventFlags = [.maskCommand, .maskAlternate]
                    let relevantMods: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
                    let currentMods = flags.intersection(relevantMods)
                    if currentMods == requiredMods {
                        DispatchQueue.main.async {
                            sorenoLog("HOTKEY: Read aloud trigger (⌥⌘R)")
                            monitor.onReadAloudTrigger?()
                        }
                    }
                }

                // Global explain-hovered shortcut: ⌥⌘E
                if type == .keyDown,
                   keyCode == 14,
                   event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    let requiredMods: CGEventFlags = [.maskCommand, .maskAlternate]
                    let relevantMods: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
                    let currentMods = flags.intersection(relevantMods)
                    if currentMods == requiredMods {
                        DispatchQueue.main.async {
                            sorenoLog("HOTKEY: Explain hovered trigger (⌥⌘E)")
                            monitor.onExplainHoveredTrigger?()
                        }
                    }
                }

                // ── Hotkey Recording Mode ──
                if monitor.isRecordingHotkey {
                    if type == .flagsChanged {
                        // Only capture on press (flag appeared), not release
                        let hasModifier = !flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty
                        if hasModifier {
                            let captured = AppConfig.Hotkey.fromModifierEvent(keyCode: keyCode, flags: flags)
                            DispatchQueue.main.async {
                                monitor.isRecordingHotkey = false
                                monitor.onHotkeyRecorded?(captured)
                            }
                        }
                    } else if type == .keyDown {
                        let captured = AppConfig.Hotkey.fromKeyEvent(keyCode: keyCode, flags: flags)
                        DispatchQueue.main.async {
                            monitor.isRecordingHotkey = false
                            monitor.onHotkeyRecorded?(captured)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                // ── Normal Hotkey Detection ──
                switch monitor.hotkey.kind {
                case .globe:
                    guard type == .flagsChanged else { break }
                    let fnPressed = flags.contains(.maskSecondaryFn)
                    let otherModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
                    let hasOther = !flags.intersection(otherModifiers).isEmpty

                    if fnPressed && !hasOther && !monitor.keyDown {
                        monitor.keyDown = true
                        DispatchQueue.main.async {
                            sorenoLog("HOTKEY: Globe/fn DOWN")
                            monitor.onFnDown?()
                        }
                    } else if !fnPressed && monitor.keyDown {
                        monitor.keyDown = false
                        DispatchQueue.main.async {
                            sorenoLog("HOTKEY: Globe/fn UP")
                            monitor.onFnUp?()
                        }
                    }

                case .modifierOnly:
                    guard type == .flagsChanged else { break }
                    let targetKeyCode = monitor.hotkey.keyCode

                    if keyCode == targetKeyCode {
                        // Check if the modifier flag for this key is now set
                        let targetModFlags = CGEventFlags(rawValue: UInt64(monitor.hotkey.modifiers))
                        let modPressed = !flags.intersection(targetModFlags).isEmpty

                        if modPressed && !monitor.keyDown {
                            // Make sure no OTHER modifiers are held
                            let allMods: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
                            let otherMods = allMods.subtracting(targetModFlags)
                            let hasOther = !flags.intersection(otherMods).isEmpty
                            if !hasOther {
                                monitor.keyDown = true
                                DispatchQueue.main.async {
                                    sorenoLog("HOTKEY: \(monitor.hotkey.displayName) DOWN")
                                    monitor.onFnDown?()
                                }
                            }
                        } else if !modPressed && monitor.keyDown {
                            monitor.keyDown = false
                            DispatchQueue.main.async {
                                sorenoLog("HOTKEY: \(monitor.hotkey.displayName) UP")
                                monitor.onFnUp?()
                            }
                        }
                    }

                case .keyCombo:
                    // For key combos, keyDown = press, we detect release via flagsChanged or keyUp
                    if type == .keyDown && keyCode == monitor.hotkey.keyCode {
                        // Check modifiers match
                        let requiredMods = CGEventFlags(rawValue: UInt64(monitor.hotkey.modifiers))
                        let relevantFlags: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
                        let currentMods = flags.intersection(relevantFlags)
                        let requiredRelevant = requiredMods.intersection(relevantFlags)

                        if currentMods == requiredRelevant && !monitor.keyDown {
                            monitor.keyDown = true
                            DispatchQueue.main.async {
                                sorenoLog("HOTKEY: \(monitor.hotkey.displayName) DOWN")
                                monitor.onFnDown?()
                            }
                            // For key combos, fire "up" after a short delay since we can't
                            // easily detect keyUp with listenOnly tap for non-modifier keys.
                            // In push-to-talk, the user holds the combo — we detect release
                            // when the modifier drops or key releases.
                        }
                    } else if type == .flagsChanged && monitor.keyDown {
                        // If a modifier was part of the combo and it's now released, fire up
                        let requiredMods = CGEventFlags(rawValue: UInt64(monitor.hotkey.modifiers))
                        let relevantFlags: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
                        let requiredRelevant = requiredMods.intersection(relevantFlags)

                        if !requiredRelevant.isEmpty {
                            let currentMods = flags.intersection(relevantFlags)
                            if currentMods != requiredRelevant {
                                monitor.keyDown = false
                                DispatchQueue.main.async {
                                    sorenoLog("HOTKEY: \(monitor.hotkey.displayName) UP (modifier released)")
                                    monitor.onFnUp?()
                                }
                            }
                        }
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            sorenoLog("CGEvent tap FAILED — need Input Monitoring permission")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        // Run the event tap on a dedicated background thread so it stays
        // active even when the menu bar popup is closed and the main run
        // loop is idle.
        let thread = Thread { [weak self] in
            guard let self else { return }
            let rl = CFRunLoopGetCurrent()!
            self.tapRunLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.soreno.eventTap"
        thread.start()
        tapThread = thread

        sorenoLog("CGEvent tap created — listening for \(hotkey.displayName) (listenOnly)")
        return true
    }

    func stop() {
        if let rl = tapRunLoop, let source = runLoopSource {
            CFRunLoopRemoveSource(rl, source, .commonModes)
            CFRunLoopStop(rl)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        keyDown = false
    }

    /// Restart the monitor (e.g., when hotkey changes)
    func restart() {
        stop()
        start()
    }

    deinit {
        stop()
    }
}
