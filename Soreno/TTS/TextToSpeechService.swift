import Foundation
import AVFoundation

enum TextToSpeechBackend {
    case apple(voiceName: String, languageCode: String)
    case enhancedPiper(voiceModel: String, runtime: String)

    var debugDescription: String {
        switch self {
        case .apple(let voiceName, let languageCode):
            return "\(voiceName) (\(languageCode))"
        case .enhancedPiper(let voiceModel, let runtime):
            return "Offline voice: \(voiceModel) via \(runtime)"
        }
    }
}

enum TextToSpeechPlaybackState: Equatable {
    case idle
    case speaking
    case paused
}

struct TextToSpeechProgress: Equatable {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let currentWordIndex: Int
    let wordCount: Int

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }
}

enum TextToSpeechError: LocalizedError {
    case emptyText
    case piperModelUnavailable
    case piperExecutableMissing
    case piperVoiceMissing
    case piperSynthesisFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text available to read aloud"
        case .piperModelUnavailable:
            return "Read-aloud is unavailable right now"
        case .piperExecutableMissing:
            return "Read-aloud is unavailable right now"
        case .piperVoiceMissing:
            return "No read-aloud voice was found"
        case .piperSynthesisFailed(let message):
            return "Read-aloud failed: \(message)"
        }
    }
}

@MainActor
final class TextToSpeechService: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    private let appleSynthesizer = AVSpeechSynthesizer()
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var audioVarispeedNode: AVAudioUnitVarispeed?
    private var audioFile: AVAudioFile?
    private var enhancedPlaybackToken: UUID?
    private let maxChunkCharacters = 900
    private var piperScriptPath: URL?
    private var piperPythonService: PiperPythonSynthesisService?
    private var pendingCleanupURL: URL?
    private var playbackWords: [String] = []
    private var currentWordIndex = 0
    private var progressTimerTask: Task<Void, Never>?
    private var appleUtteranceWordOffsets: [ObjectIdentifier: Int] = [:]
    private var appleLanguage: AppConfig.AppLanguage = .english
    private var appleVoiceIdentifier: String?
    private var appleRateMultiplier: Double = 1.0
    private var enhancedRateMultiplier: Double = 1.0
    private var enhancedStartFrame: AVAudioFramePosition = 0
    private var enhancedTotalFrames: AVAudioFramePosition = 0
    private var enhancedSampleRate: Double = 44_100
    private var suppressAppleCancellationStateChanges = false
    var onPlaybackStateChange: ((TextToSpeechPlaybackState) -> Void)?
    var onPlaybackProgress: ((TextToSpeechProgress) -> Void)?

    private(set) var playbackState: TextToSpeechPlaybackState = .idle {
        didSet {
            guard oldValue != playbackState else { return }
            onPlaybackStateChange?(playbackState)
        }
    }

    override init() {
        super.init()
        appleSynthesizer.delegate = self
    }

    func configurePiperBridge(scriptPath: URL) {
        guard piperScriptPath != scriptPath else { return }
        piperScriptPath = scriptPath
        piperPythonService = PiperPythonSynthesisService(scriptPath: scriptPath)
    }

    func stop() {
        stopProgressTimer()
        suppressAppleCancellationStateChanges = false
        if appleSynthesizer.isSpeaking {
            appleSynthesizer.stopSpeaking(at: .immediate)
        }
        if appleSynthesizer.isPaused {
            appleSynthesizer.continueSpeaking()
            appleSynthesizer.stopSpeaking(at: .immediate)
        }
        teardownEnhancedAudioPlayback(shouldDeleteArtifact: true)
        cleanupPendingAudioArtifact()
        playbackWords = []
        currentWordIndex = 0
        appleUtteranceWordOffsets = [:]
        playbackState = .idle
    }

    func pause() {
        if appleSynthesizer.isSpeaking {
            appleSynthesizer.pauseSpeaking(at: .word)
            return
        }

        guard let audioPlayerNode, audioPlayerNode.isPlaying else { return }
        audioPlayerNode.pause()
        stopProgressTimer()
        playbackState = .paused
    }

    func resume() {
        if appleSynthesizer.isPaused {
            appleSynthesizer.continueSpeaking()
            return
        }

        if playbackState == .paused, audioFile == nil, !playbackWords.isEmpty {
            let startIndex = min(max(currentWordIndex, 0), playbackWords.count - 1)
            let remainingText = playbackWords.dropFirst(startIndex).joined(separator: " ")
            _ = speakWithApple(
                text: remainingText,
                language: appleLanguage,
                voiceIdentifier: appleVoiceIdentifier,
                rateMultiplier: appleRateMultiplier,
                startingWordIndex: startIndex
            )
            return
        }

        guard let audioPlayerNode else {
            return
        }

        if let audioEngine, !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                sorenoLog("Enhanced TTS resume failed to restart audio engine: \(error.localizedDescription)")
                return
            }
        }

        audioPlayerNode.play()
        startEnhancedProgressTimer()
        playbackState = .speaking
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentProgressFraction(offsetBy: seconds))
    }

    func seek(to fraction: Double, shouldPlay requestedShouldPlay: Bool? = nil) {
        let clampedFraction = min(max(fraction, 0), 1)
        let shouldPlay = requestedShouldPlay ?? (playbackState == .speaking)

        if audioFile != nil {
            seekEnhancedPlayback(to: clampedFraction, shouldPlay: shouldPlay)
            return
        }

        if appleSynthesizer.isSpeaking || appleSynthesizer.isPaused || playbackState != .idle {
            seekApplePlayback(to: clampedFraction, shouldPlay: shouldPlay)
        }
    }

    func setRateMultiplier(_ rateMultiplier: Double) {
        let clampedRate = clampedRateMultiplier(rateMultiplier)

        if audioFile != nil {
            enhancedRateMultiplier = clampedRate
            audioVarispeedNode?.rate = Float(clampedRate)
            reportEnhancedProgress()
            return
        }

        appleRateMultiplier = clampedRate
        guard playbackState != .idle, !playbackWords.isEmpty else { return }
        seekApplePlayback(to: currentProgressFraction(offsetBy: 0), shouldPlay: playbackState == .speaking)
    }

    func speak(
        text: String,
        language: AppConfig.AppLanguage,
        preferEnhanced: Bool,
        piperModelPath: URL?,
        appleVoiceIdentifier: String?,
        rateMultiplier: Double
    ) async throws -> TextToSpeechBackend {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TextToSpeechError.emptyText
        }

        stop()
        playbackWords = Self.speechWords(from: trimmed)
        currentWordIndex = 0
        reportProgress(currentTime: 0, duration: estimatedDuration(forWordCount: playbackWords.count, rateMultiplier: rateMultiplier))

        if preferEnhanced {
            guard let piperModelPath else {
                throw TextToSpeechError.piperModelUnavailable
            }

            if let piperPythonService {
                do {
                    let result = try await piperPythonService.synthesize(text: trimmed, modelRoot: piperModelPath)
                    try playWav(at: result.wavURL, rateMultiplier: rateMultiplier)
                    return result.backend
                } catch {
                    sorenoLog("Enhanced TTS python runtime failed: \(error.localizedDescription). Falling back to binary runtime.")
                }
            }

            let artifact = try await Task.detached(priority: .userInitiated) {
                try EnhancedPiperSynthesizer.synthesize(text: trimmed, modelRoot: piperModelPath)
            }.value

            try playWav(at: artifact.wavURL, rateMultiplier: rateMultiplier)
            return .enhancedPiper(voiceModel: artifact.voiceModelName, runtime: "piper-binary")
        }

        return speakWithApple(
            text: trimmed,
            language: language,
            voiceIdentifier: appleVoiceIdentifier,
            rateMultiplier: rateMultiplier
        )
    }

    private func speakWithApple(
        text: String,
        language: AppConfig.AppLanguage,
        voiceIdentifier: String?,
        rateMultiplier: Double,
        startingWordIndex: Int = 0
    ) -> TextToSpeechBackend {
        let chunks = chunkTextForSpeech(text, maxCharacters: maxChunkCharacters)
        let selectedVoice = resolveAppleVoice(language: language, voiceIdentifier: voiceIdentifier)
        let speechRate = appleSpeechRate(for: rateMultiplier)
        appleLanguage = language
        appleVoiceIdentifier = voiceIdentifier
        appleRateMultiplier = rateMultiplier
        appleUtteranceWordOffsets = [:]
        currentWordIndex = min(max(startingWordIndex, 0), max(playbackWords.count - 1, 0))
        var wordOffset = currentWordIndex

        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.rate = speechRate
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            utterance.voice = selectedVoice
            appleUtteranceWordOffsets[ObjectIdentifier(utterance)] = wordOffset
            wordOffset += Self.speechWords(from: chunk).count
            appleSynthesizer.speak(utterance)
        }

        if !chunks.isEmpty {
            playbackState = .speaking
            reportAppleProgress()
        }

        return .apple(
            voiceName: selectedVoice?.name ?? "Aaron",
            languageCode: selectedVoice?.language ?? language.localeCode
        )
    }

    static func appleVoices(for language: AppConfig.AppLanguage) -> [AVSpeechSynthesisVoice] {
        let languageCode = language.localeCode.lowercased()

        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                let voiceLanguage = voice.language.lowercased()
                return voiceLanguage == languageCode || voiceLanguage.hasPrefix("\(languageCode)-")
            }
            .sorted {
                if $0.name == $1.name {
                    return $0.language < $1.language
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private func chunkTextForSpeech(_ text: String, maxCharacters: Int) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return []
        }

        var chunks: [String] = []
        let paragraphs = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for paragraph in paragraphs {
            appendWrapped(paragraph, maxCharacters: maxCharacters, into: &chunks)
        }

        return chunks
    }

    private func appendWrapped(_ text: String, maxCharacters: Int, into chunks: inout [String]) {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        var current = ""

        for wordSub in words {
            let word = String(wordSub)

            if current.isEmpty {
                appendWord(word, maxCharacters: maxCharacters, current: &current, chunks: &chunks)
                continue
            }

            if current.count + 1 + word.count <= maxCharacters {
                current += " " + word
            } else {
                chunks.append(current)
                current = ""
                appendWord(word, maxCharacters: maxCharacters, current: &current, chunks: &chunks)
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
    }

    private func appendWord(_ word: String, maxCharacters: Int, current: inout String, chunks: inout [String]) {
        guard word.count > maxCharacters else {
            current = word
            return
        }

        var start = word.startIndex
        while start < word.endIndex {
            let end = word.index(start, offsetBy: maxCharacters, limitedBy: word.endIndex) ?? word.endIndex
            chunks.append(String(word[start..<end]))
            start = end
        }
    }

    private func playWav(
        at url: URL,
        rateMultiplier: Double,
        startFrame: AVAudioFramePosition = 0,
        shouldPlay: Bool = true
    ) throws {
        teardownEnhancedAudioPlayback(shouldDeleteArtifact: false)

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let varispeedNode = AVAudioUnitVarispeed()
        let clampedRate = clampedRateMultiplier(rateMultiplier)
        varispeedNode.rate = Float(clampedRate)

        engine.attach(playerNode)
        engine.attach(varispeedNode)
        engine.connect(playerNode, to: varispeedNode, format: nil)
        engine.connect(varispeedNode, to: engine.mainMixerNode, format: nil)

        let file = try AVAudioFile(forReading: url)
        let playbackToken = UUID()
        let totalFrames = file.length
        let safeStartFrame = min(max(startFrame, 0), totalFrames)
        let remainingFrames = max(totalFrames - safeStartFrame, 0)

        if remainingFrames > 0 {
            playerNode.scheduleSegment(
                file,
                startingFrame: safeStartFrame,
                frameCount: AVAudioFrameCount(remainingFrames),
                at: nil
            ) { [weak self] in
                Task { @MainActor in
                    self?.handleEnhancedPlaybackCompletion(for: playbackToken)
                }
            }
        } else {
            Task { @MainActor in
                self.handleEnhancedPlaybackCompletion(for: playbackToken)
            }
        }

        engine.prepare()
        try engine.start()

        audioEngine = engine
        audioPlayerNode = playerNode
        audioVarispeedNode = varispeedNode
        audioFile = file
        enhancedPlaybackToken = playbackToken
        enhancedRateMultiplier = clampedRate
        enhancedStartFrame = safeStartFrame
        enhancedTotalFrames = totalFrames
        enhancedSampleRate = file.processingFormat.sampleRate
        pendingCleanupURL = url
        let startProgress = totalFrames > 0 ? Double(safeStartFrame) / Double(totalFrames) : 0
        currentWordIndex = playbackWords.isEmpty ? 0 : min(Int(startProgress * Double(playbackWords.count)), playbackWords.count - 1)

        if shouldPlay {
            playerNode.play()
            playbackState = .speaking
            startEnhancedProgressTimer()
        } else {
            playbackState = .paused
            reportProgress(currentTime: enhancedDuration * startProgress, duration: enhancedDuration)
        }
    }

    private func resolveAppleVoice(
        language: AppConfig.AppLanguage,
        voiceIdentifier: String?
    ) -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier,
           !voiceIdentifier.isEmpty,
           voiceIdentifier != AppConfig.systemDefaultReadAloudVoiceIdentifier,
           let exactVoice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return exactVoice
        }

        if let aaronVoice = AVSpeechSynthesisVoice(identifier: AppConfig.aaronReadAloudVoiceIdentifier) {
            return aaronVoice
        }

        return AVSpeechSynthesisVoice(language: language.localeCode) ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func appleSpeechRate(for rateMultiplier: Double) -> Float {
        let clampedMultiplier = clampedRateMultiplier(rateMultiplier)
        let defaultRate = Double(AVSpeechUtteranceDefaultSpeechRate)
        let scaledRate = defaultRate * clampedMultiplier
        return Float(
            min(
                max(scaledRate, Double(AVSpeechUtteranceMinimumSpeechRate)),
                Double(AVSpeechUtteranceMaximumSpeechRate)
            )
        )
    }

    private func clampedRateMultiplier(_ rateMultiplier: Double) -> Double {
        min(max(rateMultiplier, AppConfig.readAloudRateRange.lowerBound), AppConfig.readAloudRateRange.upperBound)
    }

    private static func speechWords(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    private func estimatedDuration(forWordCount wordCount: Int, rateMultiplier: Double) -> TimeInterval {
        guard wordCount > 0 else { return 0 }
        return (Double(wordCount) * 0.42) / clampedRateMultiplier(rateMultiplier)
    }

    private func reportProgress(currentTime: TimeInterval, duration: TimeInterval) {
        onPlaybackProgress?(
            TextToSpeechProgress(
                currentTime: min(max(currentTime, 0), max(duration, 0)),
                duration: max(duration, 0),
                currentWordIndex: min(max(currentWordIndex, 0), max(playbackWords.count - 1, 0)),
                wordCount: playbackWords.count
            )
        )
    }

    private func reportAppleProgress() {
        let duration = estimatedDuration(forWordCount: playbackWords.count, rateMultiplier: appleRateMultiplier)
        let progress = playbackWords.isEmpty ? 0 : Double(currentWordIndex) / Double(playbackWords.count)
        reportProgress(currentTime: duration * progress, duration: duration)
    }

    private func reportEnhancedProgress() {
        guard let audioPlayerNode, let nodeTime = audioPlayerNode.lastRenderTime else {
            return
        }

        let playerTime = audioPlayerNode.playerTime(forNodeTime: nodeTime)
        let playedFrames = playerTime?.sampleTime ?? 0
        let absoluteFrame = min(max(enhancedStartFrame + playedFrames, 0), max(enhancedTotalFrames, 0))
        let progress = enhancedTotalFrames > 0 ? Double(absoluteFrame) / Double(enhancedTotalFrames) : 0
        let duration = enhancedDuration
        currentWordIndex = playbackWords.isEmpty ? 0 : min(Int(progress * Double(playbackWords.count)), playbackWords.count - 1)
        reportProgress(currentTime: duration * progress, duration: duration)
    }

    private var enhancedDuration: TimeInterval {
        guard enhancedTotalFrames > 0, enhancedSampleRate > 0 else { return 0 }
        return (Double(enhancedTotalFrames) / enhancedSampleRate) / enhancedRateMultiplier
    }

    private func currentProgressFraction(offsetBy seconds: TimeInterval) -> Double {
        if audioFile != nil {
            guard enhancedDuration > 0 else { return 0 }
            guard let audioPlayerNode, let nodeTime = audioPlayerNode.lastRenderTime else {
                return Double(enhancedStartFrame) / Double(max(enhancedTotalFrames, 1))
            }
            let playedFrames = audioPlayerNode.playerTime(forNodeTime: nodeTime)?.sampleTime ?? 0
            let currentFrame = enhancedStartFrame + playedFrames
            let targetFrame = currentFrame + AVAudioFramePosition(seconds * enhancedSampleRate * enhancedRateMultiplier)
            return Double(min(max(targetFrame, 0), max(enhancedTotalFrames, 0))) / Double(max(enhancedTotalFrames, 1))
        }

        let duration = estimatedDuration(forWordCount: playbackWords.count, rateMultiplier: appleRateMultiplier)
        guard duration > 0 else { return 0 }
        let currentTime = duration * (playbackWords.isEmpty ? 0 : Double(currentWordIndex) / Double(playbackWords.count))
        return min(max((currentTime + seconds) / duration, 0), 1)
    }

    private func startEnhancedProgressTimer() {
        stopProgressTimer()
        progressTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.playbackState == .speaking else { return }
                self.reportEnhancedProgress()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func stopProgressTimer() {
        progressTimerTask?.cancel()
        progressTimerTask = nil
    }

    private func seekApplePlayback(to fraction: Double, shouldPlay: Bool) {
        guard !playbackWords.isEmpty else { return }
        let targetIndex = min(max(Int(Double(playbackWords.count) * fraction), 0), playbackWords.count - 1)
        let remainingText = playbackWords.dropFirst(targetIndex).joined(separator: " ")

        suppressAppleCancellationStateChanges = true
        if appleSynthesizer.isPaused {
            appleSynthesizer.continueSpeaking()
        }
        if appleSynthesizer.isSpeaking {
            appleSynthesizer.stopSpeaking(at: .immediate)
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.suppressAppleCancellationStateChanges = false
        }

        if shouldPlay {
            _ = speakWithApple(
                text: remainingText,
                language: appleLanguage,
                voiceIdentifier: appleVoiceIdentifier,
                rateMultiplier: appleRateMultiplier,
                startingWordIndex: targetIndex
            )
        } else {
            currentWordIndex = targetIndex
            reportAppleProgress()
            playbackState = .paused
        }
    }

    private func seekEnhancedPlayback(to fraction: Double, shouldPlay: Bool) {
        guard let url = pendingCleanupURL, enhancedTotalFrames > 0 else { return }
        let targetFrame = AVAudioFramePosition(Double(enhancedTotalFrames) * min(max(fraction, 0), 1))
        do {
            try playWav(at: url, rateMultiplier: enhancedRateMultiplier, startFrame: targetFrame, shouldPlay: shouldPlay)
        } catch {
            sorenoLog("Enhanced TTS seek failed: \(error.localizedDescription)")
        }
    }

    private func cleanupPendingAudioArtifact() {
        guard let pendingCleanupURL else { return }
        try? FileManager.default.removeItem(at: pendingCleanupURL)
        self.pendingCleanupURL = nil
    }

    private func teardownEnhancedAudioPlayback(shouldDeleteArtifact: Bool) {
        stopProgressTimer()
        enhancedPlaybackToken = nil
        audioPlayerNode?.stop()
        audioEngine?.stop()
        audioPlayerNode = nil
        audioVarispeedNode = nil
        audioFile = nil
        audioEngine = nil
        enhancedStartFrame = 0
        enhancedTotalFrames = 0

        if shouldDeleteArtifact {
            cleanupPendingAudioArtifact()
        }
    }

    private func handleEnhancedPlaybackCompletion(for token: UUID) {
        guard enhancedPlaybackToken == token else {
            return
        }

        currentWordIndex = max(playbackWords.count - 1, 0)
        reportProgress(currentTime: enhancedDuration, duration: enhancedDuration)
        teardownEnhancedAudioPlayback(shouldDeleteArtifact: true)
        playbackState = .idle
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        playbackState = .speaking
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        playbackState = .paused
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        playbackState = .speaking
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard let range = Range(characterRange, in: utterance.speechString) else {
            return
        }

        let utteranceOffset = appleUtteranceWordOffsets[ObjectIdentifier(utterance)] ?? 0
        let prefix = String(utterance.speechString[..<range.lowerBound])
        let wordIndexInUtterance = Self.speechWords(from: prefix).count
        currentWordIndex = min(max(utteranceOffset + wordIndexInUtterance, 0), max(playbackWords.count - 1, 0))
        reportAppleProgress()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking && !synthesizer.isPaused {
            currentWordIndex = max(playbackWords.count - 1, 0)
            reportAppleProgress()
            playbackState = .idle
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if suppressAppleCancellationStateChanges {
            return
        }

        if !synthesizer.isSpeaking && !synthesizer.isPaused {
            playbackState = .idle
        }
    }
}

private enum EnhancedPiperSynthesizer {
    struct Artifact {
        let wavURL: URL
        let voiceModelName: String
    }

    static func synthesize(text: String, modelRoot: URL) throws -> Artifact {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: modelRoot.path) else {
            throw TextToSpeechError.piperModelUnavailable
        }

        guard let piperBinary = findPiperBinary(modelRoot: modelRoot, fileManager: fileManager) else {
            throw TextToSpeechError.piperExecutableMissing
        }

        guard let voiceModel = findFirstVoiceModel(modelRoot: modelRoot, fileManager: fileManager) else {
            throw TextToSpeechError.piperVoiceMissing
        }

        let outputURL = fileManager.temporaryDirectory.appendingPathComponent("soreno-piper-\(UUID().uuidString).wav")

        let process = Process()
        process.executableURL = piperBinary
        process.arguments = [
            "--model", voiceModel.path,
            "--output_file", outputURL.path,
        ]

        let configURL = voiceModel.appendingPathExtension("json")
        if fileManager.fileExists(atPath: configURL.path) {
            process.arguments?.append(contentsOf: ["--config", configURL.path])
        }

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe

        try process.run()
        if let inputData = (text + "\n").data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(inputData)
        }
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? "Unknown Piper error"
            throw TextToSpeechError.piperSynthesisFailed(stderr)
        }

        return Artifact(
            wavURL: outputURL,
            voiceModelName: voiceModel.deletingPathExtension().lastPathComponent
        )
    }

    private static func findPiperBinary(modelRoot: URL, fileManager: FileManager) -> URL? {
        let candidates = [
            modelRoot.appendingPathComponent("piper"),
            modelRoot.appendingPathComponent("bin/piper"),
            URL(fileURLWithPath: "/opt/homebrew/bin/piper"),
            URL(fileURLWithPath: "/usr/local/bin/piper"),
        ]

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        return nil
    }

    private static func findFirstVoiceModel(modelRoot: URL, fileManager: FileManager) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: modelRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "onnx" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                return url
            }
        }

        return nil
    }
}
