import AppKit
import Foundation

/// Plays start/stop chimes using NSSound system sounds.
final class SoundEffects {

    /// Two-tone ascending chime.
    func playStartSound() {
        NSSound(named: .init("Morse"))?.play()
    }

    /// Single descending tone.
    func playStopSound() {
        NSSound(named: .init("Pop"))?.play()
    }
}
