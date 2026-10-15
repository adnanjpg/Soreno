import AppKit
import ApplicationServices

struct HoveredElementSnapshot {
    let appName: String
    let bundleIdentifier: String?
    let windowTitle: String?
    let role: String?
    let roleDescription: String?
    let subrole: String?
    let title: String?
    let elementDescription: String?
    let help: String?
    let value: String?
    let placeholderValue: String?
    let identifier: String?
    let parentTrail: [String]

    var promptContext: String {
        var lines: [String] = [
            "app_name: \(appName)",
            "bundle_identifier: \(bundleIdentifier ?? "unknown")",
            "window_title: \(windowTitle ?? "unknown")",
            "role: \(role ?? "unknown")",
            "role_description: \(roleDescription ?? "unknown")",
            "subrole: \(subrole ?? "unknown")",
            "title: \(title ?? "unknown")",
            "description: \(elementDescription ?? "unknown")",
            "help: \(help ?? "unknown")",
            "value: \(value ?? "unknown")",
            "placeholder: \(placeholderValue ?? "unknown")",
            "identifier: \(identifier ?? "unknown")",
        ]

        if !parentTrail.isEmpty {
            lines.append("parent_trail: \(parentTrail.joined(separator: " > "))")
        } else {
            lines.append("parent_trail: unknown")
        }

        return lines.joined(separator: "\n")
    }

    var fallbackExplanation: String {
        var parts: [String] = []
        if let label = bestLabel {
            parts.append("This appears to be \(articlePrefix(for: roleDescription ?? role) ?? "a") \(roleDescription ?? role ?? "control") labeled \(label).")
        } else if let roleDescription {
            parts.append("This appears to be \(articlePrefix(for: roleDescription) ?? "a") \(roleDescription).")
        } else if let role {
            parts.append("This appears to be a \(role).")
        } else {
            parts.append("This appears to be a control.")
        }

        parts.append("It is in \(appName)\(windowTitle.map { ", in the \($0) window" } ?? "").")

        if let help, !help.isEmpty {
            parts.append(help)
        } else if let value, !value.isEmpty, value != bestLabel {
            parts.append("Its current value is \(value).")
        } else if !parentTrail.isEmpty {
            parts.append("Nearby context: \(parentTrail.joined(separator: ", ")).")
        }

        return parts.joined(separator: " ")
    }

    private var bestLabel: String? {
        let candidates = [title, elementDescription, value, help]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
        return candidates.first.map { "\"\($0)\"" }
    }

    private func articlePrefix(for noun: String?) -> String? {
        guard let noun, let first = noun.lowercased().first else {
            return nil
        }
        return "aeiou".contains(first) ? "an" : "a"
    }
}

enum HoveredElementInspectorError: LocalizedError {
    case accessibilityUnavailable
    case frontmostAppUnavailable
    case elementUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityUnavailable:
            return "Accessibility permission is required to inspect hovered controls"
        case .frontmostAppUnavailable:
            return "No active app was found under the pointer"
        case .elementUnavailable:
            return "The current app did not expose a readable control under the pointer"
        }
    }
}

@MainActor
final class HoveredElementInspector {
    func captureHoveredElement() throws -> HoveredElementSnapshot {
        guard AXIsProcessTrusted() else {
            throw HoveredElementInspectorError.accessibilityUnavailable
        }

        let location = CGEvent(source: nil)?.location ?? .zero
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(location.x), Float(location.y), &element)

        guard error == .success, let element else {
            throw HoveredElementInspectorError.elementUnavailable
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw HoveredElementInspectorError.frontmostAppUnavailable
        }

        let parentTrail = buildParentTrail(from: element)
        let windowTitle = findWindowTitle(from: element)

        return HoveredElementSnapshot(
            appName: app.localizedName ?? "Unknown App",
            bundleIdentifier: app.bundleIdentifier,
            windowTitle: windowTitle,
            role: copyStringAttribute(kAXRoleAttribute, from: element),
            roleDescription: copyStringAttribute(kAXRoleDescriptionAttribute, from: element),
            subrole: copyStringAttribute(kAXSubroleAttribute, from: element),
            title: copyStringAttribute(kAXTitleAttribute, from: element),
            elementDescription: copyStringAttribute(kAXDescriptionAttribute, from: element),
            help: copyStringAttribute(kAXHelpAttribute, from: element),
            value: copyStringAttribute(kAXValueAttribute, from: element),
            placeholderValue: copyStringAttribute("AXPlaceholderValue", from: element),
            identifier: copyStringAttribute("AXIdentifier", from: element),
            parentTrail: parentTrail
        )
    }

    private func buildParentTrail(from element: AXUIElement) -> [String] {
        var trail: [String] = []
        var current: AXUIElement? = element

        for _ in 0..<5 {
            guard let resolvedCurrent = current else { break }

            let roleDescription = copyStringAttribute(kAXRoleDescriptionAttribute, from: resolvedCurrent)
            let title = copyStringAttribute(kAXTitleAttribute, from: resolvedCurrent)
            let label = [title, roleDescription]
                .compactMap { candidate in
                    let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed?.isEmpty == false ? trimmed : nil
                }
                .joined(separator: " ")

            if !label.isEmpty {
                trail.append(label)
            }

            current = copyElementAttribute(kAXParentAttribute, from: resolvedCurrent)
        }

        return Array(trail.reversed())
    }

    private func findWindowTitle(from element: AXUIElement) -> String? {
        var current: AXUIElement? = element

        for _ in 0..<8 {
            guard let resolvedCurrent = current else { break }
            if copyStringAttribute(kAXRoleAttribute, from: resolvedCurrent) == kAXWindowRole,
               let title = copyStringAttribute(kAXTitleAttribute, from: resolvedCurrent),
               !title.isEmpty {
                return title
            }

            current = copyElementAttribute(kAXParentAttribute, from: resolvedCurrent)
        }

        return nil
    }

    private func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let rawValue = value else {
            return nil
        }

        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let rawValue = value else {
            return nil
        }

        if let stringValue = rawValue as? String {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let numberValue = rawValue as? NSNumber {
            return numberValue.stringValue
        }

        return nil
    }
}
