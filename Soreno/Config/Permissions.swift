import Cocoa
import AVFoundation

/// Handles Accessibility and Microphone permission checks/prompts.
final class Permissions {
    // MARK: - Accessibility

    func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt once — opens System Settings > Accessibility.
    func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Microphone

    func checkMicrophone() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // Will be prompted when AVAudioEngine starts
            return false
        default:
            return false
        }
    }

    /// Request microphone access. On macOS, the system prompts automatically
    /// when AVAudioEngine installs a tap, so this is a fallback.
    func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
