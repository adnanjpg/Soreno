import SwiftUI

enum RecordingPillPhase {
    case recording
    case processing
    case readAloud
}

/// Observable store for audio levels — fed from AudioCaptureService on main thread.
final class AudioLevelStore: ObservableObject {
    private let barCount = 84
    private let minimumLevel: CGFloat = 0.0
    private let normalizationDivisor: CGFloat = 0.045
    private let noiseFloor: CGFloat = 0.025
    private let attackSmoothing: CGFloat = 0.38
    private let releaseSmoothing: CGFloat = 0.18

    @Published var levels: [CGFloat] = []

    private let waveformProfile: [CGFloat]
    private var smoothedLevel: CGFloat = 0

    init() {
        waveformProfile = AudioLevelStore.makeWaveformProfile(barCount: barCount)
        levels = Array(repeating: 0, count: barCount)
    }

    func push(_ rms: Float) {
        // Treat this as a centered level meter, not a scrolling waveform.
        // Gate out background noise first, then smooth the remaining signal.
        let normalized = min(CGFloat(rms) / normalizationDivisor, 1.0)
        let gated = max(0, normalized - noiseFloor) / (1 - noiseFloor)
        let curved = pow(gated, 0.68)
        let smoothing = curved > smoothedLevel ? attackSmoothing : releaseSmoothing
        smoothedLevel += (curved - smoothedLevel) * smoothing

        var nextLevels = levels
        for index in nextLevels.indices {
            let profile = waveformProfile[index]
            let target = minimumLevel + (smoothedLevel * profile)
            let current = nextLevels[index]
            let barSmoothing: CGFloat = target > current ? 0.46 : 0.22
            nextLevels[index] = current + ((target - current) * barSmoothing)
        }

        levels = nextLevels
    }

    func reset() {
        smoothedLevel = 0
        levels = Array(repeating: 0, count: barCount)
    }

    private static func makeWaveformProfile(barCount: Int) -> [CGFloat] {
        let midpoint = CGFloat(barCount - 1) / 2

        return (0..<barCount).map { index in
            let distanceFromCenter = abs(CGFloat(index) - midpoint) / max(midpoint, 1)
            let envelope = pow(max(0, 1 - distanceFromCenter), 1.75)
            return max(0.1, min(1.0, envelope))
        }
    }
}

final class RecordingPillPhaseStore: ObservableObject {
    @Published var phase: RecordingPillPhase = .recording
}

final class ReadAloudPlaybackStore: ObservableObject {
    @Published private(set) var words: [String] = []
    @Published private(set) var currentWordIndex = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate = 1.0
    @Published var isPaused = false

    func configure(text: String, rate: Double) {
        words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        currentWordIndex = 0
        progress = 0
        currentTime = 0
        duration = 0
        self.rate = rate
        isPaused = false
    }

    func update(progress: TextToSpeechProgress, isPaused: Bool) {
        currentWordIndex = min(max(progress.currentWordIndex, 0), max(words.count - 1, 0))
        self.progress = progress.fraction
        currentTime = progress.currentTime
        duration = progress.duration
        self.isPaused = isPaused
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func setRate(_ rate: Double) {
        self.rate = min(max(rate, AppConfig.readAloudRateRange.lowerBound), AppConfig.readAloudRateRange.upperBound)
    }

    func reset() {
        words = []
        currentWordIndex = 0
        progress = 0
        currentTime = 0
        duration = 0
        rate = 1.0
        isPaused = false
    }
}

final class LiveSubtitleStore: ObservableObject {
    struct Token: Identifiable, Equatable {
        let id: UUID
        let text: String
    }

    private let maxVisibleCharacters = 180

    @Published private(set) var tokens: [Token] = []

    var isAtCharacterCapacity: Bool {
        characterCount(for: tokens) >= maxVisibleCharacters
    }

    func setWords(_ words: [String]) {
        let normalized = words.filter { !$0.isEmpty }
        guard !normalized.isEmpty else {
            clear()
            return
        }

        var next: [Token] = []
        var oldIndex = tokens.count - 1

        for word in normalized.reversed() {
            if oldIndex >= 0 {
                let existing = tokens[oldIndex]
                if existing.text.caseInsensitiveCompare(word) == .orderedSame {
                    next.append(existing)
                    oldIndex -= 1
                    continue
                }
            }

            next.append(Token(id: UUID(), text: word))
        }

        let rebuilt = boundedByCharacterBudget(Array(next.reversed()))
        if rebuilt != tokens {
            tokens = rebuilt
        }
    }

    func clear() {
        if !tokens.isEmpty {
            tokens = []
        }
    }

    private func boundedByCharacterBudget(_ candidates: [Token]) -> [Token] {
        var keptFromEnd: [Token] = []
        var totalCharacters = 0

        for token in candidates.reversed() {
            let tokenLength = token.text.count

            if keptFromEnd.isEmpty, tokenLength > maxVisibleCharacters {
                keptFromEnd.append(token)
                break
            }

            let separatorLength = keptFromEnd.isEmpty ? 0 : 1
            if totalCharacters + separatorLength + tokenLength > maxVisibleCharacters {
                break
            }

            keptFromEnd.append(token)
            totalCharacters += separatorLength + tokenLength
        }

        return Array(keptFromEnd.reversed())
    }

    private func characterCount(for tokens: [Token]) -> Int {
        let letters = tokens.reduce(0) { $0 + $1.text.count }
        let spaces = max(0, tokens.count - 1)
        return letters + spaces
    }
}

/// The floating pill content — shows a dynamic waveform during recording.
struct RecordingPillView: View {
    @ObservedObject var levelStore: AudioLevelStore
    @ObservedObject var subtitleStore: LiveSubtitleStore
    @ObservedObject var phaseStore: RecordingPillPhaseStore
    @ObservedObject var readAloudStore: ReadAloudPlaybackStore
    let onToggleReadAloudPlayback: () -> Void
    let onSkipReadAloudBackward: () -> Void
    let onSkipReadAloudForward: () -> Void
    let onBeginReadAloudScrub: () -> Void
    let onEndReadAloudScrub: (Double) -> Void
    let onChangeReadAloudSpeed: (Double) -> Void
    let onStopReadAloud: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isScrubbingReadAloud = false
    @State private var scrubProgress = 0.0

    var body: some View {
        Group {
            if phaseStore.phase == .readAloud {
                readAloudContent
            } else {
                recordingContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 0)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        )
    }

    private var recordingContent: some View {
        VStack(spacing: 8) {
            if phaseStore.phase == .recording {
                HStack(spacing: 1.5) {
                    ForEach(Array(levelStore.levels.enumerated()), id: \.offset) { _, level in
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white : Color.black)
                            .frame(width: 2.5, height: barHeight(for: level))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .center)
            } else {
                ZStack {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.primary)

                        Text("Processing audio")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    HStack {
                        Spacer()
                        Button {
                            RecordingPillWindow.shared.requestCancelProcessing()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .center)
            }

            HStack(spacing: 5) {
                ForEach(Array(subtitleStore.tokens.enumerated()), id: \.element.id) { index, token in
                    Text(token.text)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .foregroundStyle(Color.primary)
                        .opacity(subtitleOpacity(at: index, total: subtitleStore.tokens.count, enabled: subtitleStore.isAtCharacterCapacity))
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 34,
                maxHeight: 34,
                alignment: subtitleStore.isAtCharacterCapacity ? .leading : .center
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var readAloudContent: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Label(readAloudStore.isPaused ? "Paused" : "Reading", systemImage: readAloudStore.isPaused ? "pause.circle.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)

                playbackButton(systemName: "gobackward.10", action: onSkipReadAloudBackward)
                playbackButton(systemName: readAloudStore.isPaused ? "play.fill" : "pause.fill", action: onToggleReadAloudPlayback)
                playbackButton(systemName: "goforward.10", action: onSkipReadAloudForward)

                Slider(
                    value: Binding(
                        get: { isScrubbingReadAloud ? scrubProgress : readAloudStore.progress },
                        set: { scrubProgress = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: handleReadAloudScrubEditingChanged
                )
                .controlSize(.small)

                Text(timeLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 78, alignment: .trailing)

                HStack(spacing: 3) {
                    playbackButton(systemName: "minus") {
                        changeReadAloudSpeed(by: -0.25)
                    }

                    Text(speedLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .center)

                    playbackButton(systemName: "plus") {
                        changeReadAloudSpeed(by: 0.25)
                    }
                }

                playbackButton(systemName: "xmark.circle.fill", action: onStopReadAloud)
            }
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .center)

            HStack(spacing: 6) {
                ForEach(visibleReadAloudWordIndices, id: \.self) { index in
                    let isCurrent = index == displayedReadAloudWordIndex
                    let isPast = index < displayedReadAloudWordIndex

                    Text(readAloudStore.words[index])
                        .font(.system(size: isCurrent ? 16 : 15, weight: isCurrent ? .bold : .semibold, design: .rounded))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? Color(nsColor: .controlBackgroundColor) : Color.primary)
                        .padding(.horizontal, isCurrent ? 8 : 0)
                        .padding(.vertical, isCurrent ? 4 : 0)
                        .background(
                            Capsule()
                                .fill(isCurrent ? Color.primary : Color.clear)
                        )
                        .opacity(isPast ? 0.35 : 1)
                        .scaleEffect(isCurrent ? 1.06 : 1)
                        .animation(.spring(response: 0.28, dampingFraction: 0.76), value: displayedReadAloudWordIndex)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .center)
            .clipped()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func playbackButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func handleReadAloudScrubEditingChanged(_ isEditing: Bool) {
        if isEditing {
            scrubProgress = readAloudStore.progress
            isScrubbingReadAloud = true
            onBeginReadAloudScrub()
        } else {
            let targetProgress = scrubProgress
            onEndReadAloudScrub(targetProgress)
            isScrubbingReadAloud = false
        }
    }

    private var displayedReadAloudWordIndex: Int {
        guard !readAloudStore.words.isEmpty else { return 0 }
        if isScrubbingReadAloud {
            return min(max(Int(Double(readAloudStore.words.count) * scrubProgress), 0), readAloudStore.words.count - 1)
        }
        return readAloudStore.currentWordIndex
    }

    private var visibleReadAloudWordIndices: [Int] {
        guard !readAloudStore.words.isEmpty else { return [] }
        let visibleWordCount = 4
        let start = min(max(displayedReadAloudWordIndex - 1, 0), max(readAloudStore.words.count - visibleWordCount, 0))
        let end = min(start + visibleWordCount, readAloudStore.words.count)
        return Array(start..<end)
    }

    private var timeLabel: String {
        let currentTime = isScrubbingReadAloud ? readAloudStore.duration * scrubProgress : readAloudStore.currentTime
        return "\(formatTime(currentTime)) / \(formatTime(readAloudStore.duration))"
    }

    private var speedLabel: String {
        String(format: "%.2fx", readAloudStore.rate)
    }

    private func changeReadAloudSpeed(by delta: Double) {
        let nextRate = min(max(readAloudStore.rate + delta, AppConfig.readAloudRateRange.lowerBound), AppConfig.readAloudRateRange.upperBound)
        onChangeReadAloudSpeed(nextRate)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let seconds = Int(time.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func barHeight(for level: CGFloat) -> CGFloat {
        let minH: CGFloat = 3
        let maxH: CGFloat = 34
        return minH + (maxH - minH) * level
    }

    private func subtitleOpacity(at index: Int, total: Int, enabled: Bool) -> Double {
        guard enabled, total > 1 else { return 1.0 }
        let progress = Double(index) / Double(total - 1)
        return 0.35 + (0.65 * progress)
    }
}
