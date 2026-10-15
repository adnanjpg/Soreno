import Cocoa
import SwiftUI

/// Floating, non-activating pill window that shows a waveform during recording.
/// Uses NSPanel so it doesn't steal focus from the active app.
final class RecordingPillWindow {
    static let shared = RecordingPillWindow()

    private struct Layout {
        let frame: NSRect
    }

    private var panel: NSPanel?
    private let levelStore = AudioLevelStore()
    private let subtitleStore = LiveSubtitleStore()
    private let phaseStore = RecordingPillPhaseStore()
    private let readAloudStore = ReadAloudPlaybackStore()
    var onCancelProcessing: (() -> Void)?
    var onToggleReadAloudPlayback: (() -> Void)?
    var onSkipReadAloudBackward: (() -> Void)?
    var onSkipReadAloudForward: (() -> Void)?
    var onBeginReadAloudScrub: (() -> Void)?
    var onEndReadAloudScrub: ((Double) -> Void)?
    var onChangeReadAloudSpeed: ((Double) -> Void)?
    var onStopReadAloud: (() -> Void)?

    private init() {}

    /// Push an audio level (RMS) to the waveform. Called from main thread.
    func pushLevel(_ rms: Float) {
        levelStore.push(rms)
    }

    func updateSubtitleWords(_ words: [String]) {
        subtitleStore.setWords(words)
    }

    func showRecording() {
        phaseStore.phase = .recording
        ensurePanel()
    }

    func showProcessing() {
        levelStore.reset()
        phaseStore.phase = .processing
        ensurePanel()
    }

    func showReadAloud(text: String, rate: Double = 1.0) {
        readAloudStore.configure(text: text, rate: rate)
        phaseStore.phase = .readAloud
        ensurePanel()
    }

    func ensureReadAloudVisible(text: String) {
        if readAloudStore.words.isEmpty, !text.isEmpty {
            readAloudStore.configure(text: text, rate: readAloudStore.rate)
        }
        phaseStore.phase = .readAloud
        ensurePanel()
    }

    func updateReadAloudProgress(_ progress: TextToSpeechProgress, isPaused: Bool) {
        readAloudStore.update(progress: progress, isPaused: isPaused)
    }

    func setReadAloudPaused(_ paused: Bool) {
        readAloudStore.setPaused(paused)
    }

    func updateReadAloudRate(_ rate: Double) {
        readAloudStore.setRate(rate)
    }

    func show() {
        showRecording()
    }

    func requestCancelProcessing() {
        onCancelProcessing?()
    }

    private func ensurePanel() {
        let layout = currentLayout()

        guard panel == nil else {
            panel?.setFrame(layout.frame, display: true, animate: false)
            panel?.orderFrontRegardless()
            return
        }

        let pillView = RecordingPillView(
            levelStore: levelStore,
            subtitleStore: subtitleStore,
            phaseStore: phaseStore,
            readAloudStore: readAloudStore,
            onToggleReadAloudPlayback: { [weak self] in self?.onToggleReadAloudPlayback?() },
            onSkipReadAloudBackward: { [weak self] in self?.onSkipReadAloudBackward?() },
            onSkipReadAloudForward: { [weak self] in self?.onSkipReadAloudForward?() },
            onBeginReadAloudScrub: { [weak self] in self?.onBeginReadAloudScrub?() },
            onEndReadAloudScrub: { [weak self] progress in self?.onEndReadAloudScrub?(progress) },
            onChangeReadAloudSpeed: { [weak self] rate in self?.onChangeReadAloudSpeed?(rate) },
            onStopReadAloud: { [weak self] in self?.onStopReadAloud?() }
        )
        let hostingView = NSHostingView(rootView: pillView)
        hostingView.frame = NSRect(origin: .zero, size: layout.frame.size)

        let panel = NSPanel(
            contentRect: layout.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = hostingView
        panel.hidesOnDeactivate = false

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
        phaseStore.phase = .recording
        levelStore.reset()
        subtitleStore.clear()
        readAloudStore.reset()
    }

    private func currentLayout() -> Layout {
        let basePillWidth: CGFloat = 420
        let preferredPillWidth = basePillWidth * 2.2
        let pillHeight: CGFloat = 104
        let screen = preferredScreen() ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pillWidth = min(preferredPillWidth, screenFrame.width * 0.9)
        let x = round(screenFrame.midX - pillWidth / 2)
        let y = round(screenFrame.minY + 40)
        return Layout(frame: NSRect(x: x, y: y, width: pillWidth, height: pillHeight))
    }

    private func preferredScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
