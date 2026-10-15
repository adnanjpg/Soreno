import Cocoa

/// Inserts text into the active application via clipboard + CGEvent Cmd+V.
/// Ported from electron/resources/macos-paste-helper.swift and main.js typeIntoActiveApp.
final class TextInserter {
    struct CapturedText {
        enum Source: String {
            case accessibilitySelection = "accessibility selection"
            case copiedSelection = "selection copy"
            case clipboard = "clipboard"
        }

        let text: String
        let source: Source
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private let queue = DispatchQueue(label: "com.soreno.textInserter")
    private let semaphore = DispatchSemaphore(value: 1)

    /// Insert text into whatever app currently has keyboard focus.
    /// When `finalClipboardText` is provided, that text replaces the temporary paste payload
    /// after Cmd+V so the inserted result remains available for manual paste.
    func insertText(_ text: String, finalClipboardText: String? = nil) {
        let payload = text.hasSuffix(" ") ? text : text + " "

        queue.async { [weak self] in
            self?.semaphore.wait()
            defer { self?.semaphore.signal() }

            sorenoLog("TextInserter: writing '\(payload)' to clipboard")

            let pasteboard = NSPasteboard.general
            let previousContents = finalClipboardText == nil ? Self.snapshotPasteboard(pasteboard) : nil

            // Write transcription to clipboard
            Self.replacePasteboardContents(with: payload, on: pasteboard)

            // Small delay to ensure clipboard is written
            Thread.sleep(forTimeInterval: 0.05)

            // Simulate Cmd+V at HID level
            sorenoLog("TextInserter: simulating Cmd+V paste")
            Self.simulatePaste()

            // Restore the previous clipboard, or persist the inserted text for manual reuse.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let pb = NSPasteboard.general
                if let finalClipboardText {
                    Self.replacePasteboardContents(with: finalClipboardText, on: pb)
                    sorenoLog("TextInserter: clipboard updated with inserted text")
                } else if let previousContents {
                    Self.restorePasteboard(pb, from: previousContents)
                    sorenoLog("TextInserter: clipboard restored")
                }
            }
        }
    }

    /// Copy the current text selection and return it without permanently changing the clipboard.
    func captureSelectedText() -> CapturedText? {
        if let directSelection = captureSelectedTextViaAccessibility() {
            return CapturedText(text: directSelection, source: .accessibilitySelection)
        }

        if let copiedSelection = captureSelectedTextViaClipboardCopy() {
            return CapturedText(text: copiedSelection, source: .copiedSelection)
        }

        return nil
    }

    func captureClipboardText() -> CapturedText? {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return CapturedText(text: text, source: .clipboard)
    }

    private func captureSelectedTextViaClipboardCopy() -> String? {
        var captured: String?
        let done = DispatchSemaphore(value: 0)

        queue.async { [weak self] in
            self?.semaphore.wait()
            defer {
                self?.semaphore.signal()
                done.signal()
            }

            let pasteboard = NSPasteboard.general
            let previous = Self.snapshotPasteboard(pasteboard)

            pasteboard.clearContents()
            Self.simulateCopy()
            Thread.sleep(forTimeInterval: 0.12)

            captured = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)

            Self.restorePasteboard(pasteboard, from: previous)
        }

        _ = done.wait(timeout: .now() + 1.5)
        if let captured, !captured.isEmpty {
            return captured
        }
        return nil
    }

    private func captureSelectedTextViaAccessibility() -> String? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        if let focusedElement = focusedElement(),
           let selectedText = selectedText(from: focusedElement) {
            return selectedText
        }

        return nil
    }

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        if let focusedElement = Self.copyElementAttribute(
            from: systemWideElement,
            attribute: kAXFocusedUIElementAttribute as CFString
        ) {
            return focusedElement
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return Self.copyElementAttribute(from: appElement, attribute: kAXFocusedUIElementAttribute as CFString)
    }

    private func selectedText(from startingElement: AXUIElement) -> String? {
        var currentElement: AXUIElement? = startingElement

        for _ in 0..<5 {
            guard let element = currentElement else {
                break
            }

            if let selectedText = Self.copyStringAttribute(from: element, attribute: kAXSelectedTextAttribute as CFString),
               !selectedText.isEmpty {
                return selectedText
            }

            if let selectedRange = Self.copyRangeAttribute(from: element, attribute: kAXSelectedTextRangeAttribute as CFString),
               selectedRange.length > 0,
               let fullValue = Self.copyStringAttribute(
                    from: element,
                    attribute: kAXValueAttribute as CFString,
                    trimWhitespace: false
               ),
               NSMaxRange(selectedRange) <= fullValue.utf16.count {
                let nsValue = fullValue as NSString
                let selectedText = nsValue.substring(with: selectedRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if !selectedText.isEmpty {
                    return selectedText
                }
            }

            currentElement = Self.copyElementAttribute(from: element, attribute: kAXParentAttribute as CFString)
        }

        return nil
    }

    private static func copyElementAttribute(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func copyStringAttribute(
        from element: AXUIElement,
        attribute: CFString,
        trimWhitespace: Bool = true
    ) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value else {
            return nil
        }

        guard let stringValue = value as? String else {
            return nil
        }

        if trimWhitespace {
            return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return stringValue
    }

    private static func copyRangeAttribute(from element: AXUIElement, attribute: CFString) -> NSRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        let castValue = unsafeBitCast(axValue, to: AXValue.self)
        guard AXValueGetType(castValue) == .cfRange else {
            return nil
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(castValue, .cfRange, &selectedRange) else {
            return nil
        }

        guard selectedRange.location >= 0, selectedRange.length > 0 else {
            return nil
        }

        return NSRange(location: selectedRange.location, length: selectedRange.length)
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var storedData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    storedData[type] = data
                }
            }
            return storedData
        }

        return PasteboardSnapshot(items: items)
    }

    private static func replacePasteboardContents(with text: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard, from snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            return
        }

        let restoredItems = snapshot.items.compactMap { itemData -> NSPasteboardItem? in
            let pasteboardItem = NSPasteboardItem()
            var hasData = false

            for (type, data) in itemData {
                hasData = true
                pasteboardItem.setData(data, forType: type)
            }

            return hasData ? pasteboardItem : nil
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }

    /// Post Cmd+V via CGEvent at HID level — bypasses focus issues.
    private static func simulatePaste() {
        let src = CGEventSource(stateID: .hidSystemState)

        // keycode 9 = 'v'
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else {
            NSLog("TextInserter: Failed to create CGEvent")
            return
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }

    private static func simulateCopy() {
        let src = CGEventSource(stateID: .hidSystemState)

        // keycode 8 = 'c'
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false) else {
            NSLog("TextInserter: Failed to create copy CGEvent")
            return
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }
}
