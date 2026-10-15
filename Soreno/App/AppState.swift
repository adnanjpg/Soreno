import Foundation
import SwiftUI
import Combine
import AVFoundation
import AppKit

/// Simple file logger so we can see logs even when launched via `open`.
func sorenoLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    NSLog("[Soreno] \(msg)")
    let logPath = NSHomeDirectory() + "/Library/Logs/Soreno.log"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

/// Central state object that orchestrates all services.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State
    @Published var isRecording = false
    @Published var isModelLoaded = false
    @Published var isModelLoading = false
    @Published var statusText = "Initializing..."
    @Published var lastTranscription = ""
    @Published var transcriptions: [AppConfig.TranscriptHistoryEntry] = []
    @Published var liveSubtitleWords: [String] = []
    @Published var errorMessage: String?
    @Published var isRecordingHotkey = false
    @Published var copiedToClipboard = false
    @Published var lastReadAloudEngineDescription: String?
    @Published private(set) var isRecordingProcessing = false
    @Published private(set) var isReadAloudPlaying = false
    @Published private(set) var isReadAloudPaused = false

    var isInitializingUI: Bool {
        !isModelLoaded && (isModelLoading || statusText == "Initializing..." || statusText == "Loading speech-to-text...")
    }

    var isReadAloudActive: Bool {
        isReadAloudPlaying || isReadAloudPaused
    }

    // MARK: - Services
    let audioCaptureService = AudioCaptureService()
    let whisperService = WhisperService()
    let globeKeyMonitor = GlobeKeyMonitor()
    let hotkeyManager = HotkeyManager()
    let textInserter = TextInserter()
    let textToSpeechService = TextToSpeechService()
    let soundEffects = SoundEffects()
    let permissions = Permissions()
    let hoveredElementInspector = HoveredElementInspector()
    let modelFeatureManager: ModelFeatureManager
    private var bridgeClient: PythonBridgeClient?
    private var whisperBridgeService: WhisperBridgeService?
    private var llamaPostProcessingService: LlamaPostProcessingService?
    private var uiElementExplanationService: UIElementExplanationService?

    // MARK: - Config
    @Published var config: AppConfig

    private var cancellables = Set<AnyCancellable>()
    private var isConfiguringTranscriptionBackend = false
    private var liveSubtitleTask: Task<Void, Never>?
    private var lastNonSorenoApplication: NSRunningApplication?
    private let minimumTranscriptionSampleCount = 16_000
    private var processingTask: Task<Void, Never>?
    private var activeProcessingID = UUID()
    private var activeReadAloudStatusText = "Reading..."
    private var activeReadAloudText = ""
    private var isManagingReadAloudStatus = false
    private var isStartingReadAloud = false
    private var shouldResumeReadAloudAfterScrub = false

    init() {
        let config = AppConfig()
        self.config = config
        self.modelFeatureManager = ModelFeatureManager(config: config)
        self.transcriptions = Array(config.recentTranscriptHistoryEntries.suffix(20))

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.lastNonSorenoApplication = frontmost
        }

        setupHotkeyCallbacks()
        setupAudioCaptureCallbacks()
        setupRecordingPillCallbacks()
        setupReadAloudCallbacks()
        observeConfigChanges()
        observeWorkspaceActivation()

        // Forward config changes to AppState so SwiftUI re-renders
        config.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        DispatchQueue.main.async { [weak self] in
            self?.openDesktopWindowOnLaunchIfNeeded()
        }

        Task { await bootstrap() }
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        sorenoLog("Bootstrap starting...")

        // Check permissions
        let hasAx = permissions.checkAccessibility()
        sorenoLog("Accessibility: \(hasAx)")

        if !hasAx {
            bringAppToFrontForSystemDialog()
            permissions.promptAccessibility()
        }

        // Request microphone permission upfront so the dialog doesn't
        // interrupt a recording session later.
        let hasMic = permissions.checkMicrophone()
        sorenoLog("Microphone: \(hasMic)")
        if !hasMic {
            bringAppToFrontForSystemDialog()
            let granted = await permissions.requestMicrophone()
            sorenoLog("Microphone permission granted: \(granted)")
            if !granted {
                errorMessage = "Microphone access is required for transcription."
            }
        }

        pruneUnsafePostProcessingEntriesIfNeeded()

        do {
            let bootstrap = try LocalModelBootstrap.bootstrapIfNeeded()
            bridgeClient = PythonBridgeClient(scriptPath: bootstrap.pythonBridgeScriptPath)
            textToSpeechService.configurePiperBridge(scriptPath: bootstrap.pythonBridgeScriptPath)
            refreshOptionalBridgeServices()
            sorenoLog("Backend model bootstrap complete at \(bootstrap.modelsRoot.path)")
        } catch {
            sorenoLog("Backend model bootstrap failed: \(error.localizedDescription)")
        }

        await configureTranscriptionBackend(forceReload: true)

        // Start CGEvent tap for hotkey (needs Input Monitoring permission)
        startHotkeyMonitor()

        sorenoLog("Bootstrap complete.")
    }

    private func bringAppToFrontForSystemDialog() {
        NSApp.activate(ignoringOtherApps: true)
        if let keyWindow = NSApp.keyWindow {
            keyWindow.makeKeyAndOrderFront(nil)
        } else if let anyWindow = NSApp.windows.first(where: { $0.isVisible }) {
            anyWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func openDesktopWindowOnLaunchIfNeeded() {
        let shouldOpenDesktopWindow = !config.hasCompletedFirstLaunch || config.openDesktopAppOnLaunch
        guard shouldOpenDesktopWindow else {
            return
        }

        DesktopAppWindowManager.shared.show(appState: self)

        if !config.hasCompletedFirstLaunch {
            config.hasCompletedFirstLaunch = true
        }
    }

    // MARK: - Hotkey Callbacks

    private func setupHotkeyCallbacks() {
        hotkeyManager.onActivate = { [weak self] in
            Task { @MainActor in
                self?.setActive(true)
            }
        }
        hotkeyManager.onDeactivate = { [weak self] in
            Task { @MainActor in
                self?.setActive(false)
            }
        }
    }

    private func setupAudioCaptureCallbacks() {
        audioCaptureService.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                RecordingPillWindow.shared.pushLevel(level)
            }
        }
        audioCaptureService.onCaptureFailure = { [weak self] error in
            Task { @MainActor in
                self?.handleAudioCaptureFailure(error)
            }
        }
    }

    private func setupRecordingPillCallbacks() {
        RecordingPillWindow.shared.onCancelProcessing = { [weak self] in
            Task { @MainActor in
                self?.cancelProcessing()
            }
        }
        RecordingPillWindow.shared.onToggleReadAloudPlayback = { [weak self] in
            Task { @MainActor in
                self?.toggleReadAloudPause()
            }
        }
        RecordingPillWindow.shared.onSkipReadAloudBackward = { [weak self] in
            Task { @MainActor in
                self?.skipReadAloud(by: -10)
            }
        }
        RecordingPillWindow.shared.onSkipReadAloudForward = { [weak self] in
            Task { @MainActor in
                self?.skipReadAloud(by: 10)
            }
        }
        RecordingPillWindow.shared.onBeginReadAloudScrub = { [weak self] in
            Task { @MainActor in
                self?.beginReadAloudScrub()
            }
        }
        RecordingPillWindow.shared.onEndReadAloudScrub = { [weak self] progress in
            Task { @MainActor in
                self?.endReadAloudScrub(at: progress)
            }
        }
        RecordingPillWindow.shared.onChangeReadAloudSpeed = { [weak self] rate in
            Task { @MainActor in
                self?.setReadAloudRate(rate)
            }
        }
        RecordingPillWindow.shared.onStopReadAloud = { [weak self] in
            Task { @MainActor in
                self?.stopReadAloud()
            }
        }
    }

    private func setupReadAloudCallbacks() {
        textToSpeechService.onPlaybackStateChange = { [weak self] state in
            self?.handleReadAloudPlaybackStateChange(state)
        }
        textToSpeechService.onPlaybackProgress = { [weak self] progress in
            self?.handleReadAloudPlaybackProgress(progress)
        }
    }

    // MARK: - Config Observation

    private func observeConfigChanges() {
        config.$hotkey
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newHotkey in
                guard let self else { return }
                sorenoLog("Hotkey changed to: \(newHotkey.displayName)")
                self.globeKeyMonitor.hotkey = newHotkey
                self.globeKeyMonitor.restart()
            }
            .store(in: &cancellables)

        config.$mode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newMode in
                self?.hotkeyManager.mode = newMode
            }
            .store(in: &cancellables)

        config.$isSmartPostProcessingEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                sorenoLog("Smart post-processing \(enabled ? "enabled" : "disabled")")
                self?.refreshOptionalBridgeServices()
            }
            .store(in: &cancellables)

        config.$readAloudRate
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                guard let self else { return }
                self.textToSpeechService.setRateMultiplier(rate)
                RecordingPillWindow.shared.updateReadAloudRate(rate)
            }
            .store(in: &cancellables)

        config.$isMultiLanguageSTTEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard ProductFlags.supportsMultiLanguage else { return }
                sorenoLog("Multi-language STT \(enabled ? "enabled" : "disabled")")
                self?.refreshOptionalBridgeServices()
                Task { @MainActor [weak self] in
                    await self?.configureTranscriptionBackend(forceReload: true)
                }
            }
            .store(in: &cancellables)

        config.$activeLanguage
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] language in
                guard ProductFlags.supportsMultiLanguage else { return }
                sorenoLog("Active language switched to \(language.displayName)")
                Task { @MainActor [weak self] in
                    await self?.configureTranscriptionBackend(forceReload: true)
                }
            }
            .store(in: &cancellables)

        modelFeatureManager.$modelStates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshOptionalBridgeServices()
                Task { @MainActor [weak self] in
                    await self?.configureTranscriptionBackend(forceReload: false)
                }
            }
            .store(in: &cancellables)
    }

    private func observeWorkspaceActivation() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                guard let self else { return }
                if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self.lastNonSorenoApplication = app
                }
            }
            .store(in: &cancellables)
    }

    private func refreshOptionalBridgeServices() {
        guard let bridgeClient else {
            whisperBridgeService = nil
            llamaPostProcessingService = nil
            uiElementExplanationService = nil
            return
        }

        if ProductFlags.supportsMultiLanguage,
           config.isMultiLanguageSTTEnabled,
           let whisperModelPath = modelFeatureManager.installedModelPath(for: .whisperMultilingual) {
            whisperBridgeService = WhisperBridgeService(
                bridgeClient: bridgeClient,
                modelPath: whisperModelPath
            )
        } else {
            whisperBridgeService = nil
        }

        if isSmartPostProcessingAvailable,
           let llamaModelPath = modelFeatureManager.installedModelPath(for: .llamaPostProcessing) {
            llamaPostProcessingService = LlamaPostProcessingService(
                bridgeClient: bridgeClient,
                modelPath: llamaModelPath
            )
            uiElementExplanationService = UIElementExplanationService(
                bridgeClient: bridgeClient,
                modelPath: llamaModelPath
            )
        } else {
            llamaPostProcessingService = nil
            uiElementExplanationService = nil
        }
    }

    // MARK: - Hotkey Monitor (CGEvent tap)

    private func startHotkeyMonitor() {
        globeKeyMonitor.hotkey = config.hotkey
        globeKeyMonitor.onFnDown = { [weak self] in
            self?.hotkeyManager.handleFnDown()
        }
        globeKeyMonitor.onFnUp = { [weak self] in
            self?.hotkeyManager.handleFnUp()
        }
        globeKeyMonitor.onHotkeyRecorded = { [weak self] captured in
            Task { @MainActor in
                guard let self else { return }
                sorenoLog("Hotkey recorded: \(captured.displayName)")
                self.isRecordingHotkey = false
                self.config.hotkey = captured
            }
        }
        globeKeyMonitor.onReadAloudTrigger = { [weak self] in
            self?.readSelectedTextAloud()
        }
        globeKeyMonitor.onExplainHoveredTrigger = { [weak self] in
            self?.explainHoveredElementAloud()
        }
        let success = globeKeyMonitor.start()
        if success {
            sorenoLog("Hotkey monitor started — \(config.hotkey.displayName) (CGEvent tap).")
        } else {
            sorenoLog("Hotkey monitor FAILED — need Input Monitoring permission.")
        }
    }

    // MARK: - Hotkey Recording (for settings UI)

    func startRecordingHotkey() {
        sorenoLog("Starting hotkey recording...")
        isRecordingHotkey = true
        globeKeyMonitor.isRecordingHotkey = true
    }

    func stopRecordingHotkey() {
        isRecordingHotkey = false
        globeKeyMonitor.isRecordingHotkey = false
    }

    // MARK: - Recording Control

    func setActive(_ active: Bool) {
        guard isModelLoaded else {
            hotkeyManager.syncActiveState(false)
            return
        }

        if active {
            guard !isRecordingProcessing else {
                sorenoLog("Ignoring recording activation while previous audio is still processing")
                reconcileRecordingPresentation()
                return
            }
            guard !isRecording else {
                reconcileRecordingPresentation()
                return
            }
            startRecording()
        } else if isRecording {
            stopRecording()
        } else {
            reconcileRecordingPresentation()
        }
    }

    func toggleRecording() {
        setActive(!isRecording)
    }

    func selectActiveLanguage(_ language: AppConfig.AppLanguage) {
        guard ProductFlags.supportsMultiLanguage else {
            config.activeLanguage = .english
            config.isMultiLanguageSTTEnabled = false
            return
        }
        if !language.isEnglish {
            config.isMultiLanguageSTTEnabled = true
        }
        config.activeLanguage = language
    }

    private func startRecording() {
        sorenoLog("START recording")
        if isReadAloudActive || isStartingReadAloud {
            stopReadAloud()
        }

        isRecording = true
        isRecordingProcessing = false
        errorMessage = nil
        statusText = "Recording..."
        liveSubtitleWords = []
        soundEffects.playStartSound()
        reconcileRecordingPresentation()
        startLiveSubtitles()

        do {
            try audioCaptureService.start()
            sorenoLog("Audio capture started — accumulating samples")
            hotkeyManager.syncActiveState(true)
        } catch {
            sorenoLog("Audio capture ERROR: \(error)")
            errorMessage = "Audio capture failed: \(error.localizedDescription)"
            stopLiveSubtitles()
            isRecording = false
            isRecordingProcessing = false
            statusText = "Error"
            hotkeyManager.syncActiveState(false)
            reconcileRecordingPresentation()
        }
    }

    private func stopRecording() {
        sorenoLog("STOP recording")
        isRecording = false
        isRecordingProcessing = true
        statusText = "Processing..."
        soundEffects.playStopSound()
        stopLiveSubtitles()
        hotkeyManager.syncActiveState(false)
        reconcileRecordingPresentation()

        audioCaptureService.stop()
        let samples = audioCaptureService.consumeCapturedSamples()

        guard !samples.isEmpty else {
            sorenoLog("No audio samples captured")
            completeRecordingProcessing()
            return
        }

        guard samples.count >= minimumTranscriptionSampleCount else {
            sorenoLog("Suppressing transcription for short capture (\(samples.count) samples)")
            completeRecordingProcessing()
            return
        }

        sorenoLog("Transcribing \(samples.count) samples (\(String(format: "%.1f", Float(samples.count) / 16000.0))s)...")
        let processingID = UUID()
        activeProcessingID = processingID

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rawText = try await transcribeWithLanguageBackend(samples)
                try Task.checkCancellation()
                let postProcessingEnabled = isSmartPostProcessingAvailable && llamaPostProcessingService != nil
                let text: String
                if isSmartPostProcessingAvailable, let postProcessor = llamaPostProcessingService {
                    let context = PostProcessingContext(
                        language: currentLanguageHint(),
                        profileName: "Default",
                        systemPrompt: config.userProfilePrompt,
                        customDictionary: sanitizedDictionaryPairs(),
                        correctionMemory: sanitizedCorrectionMemoryPairs()
                    )
                    text = await postProcessor.processOrFallback(rawTranscript: rawText, context: context)
                } else {
                    text = rawText
                }
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.activeProcessingID == processingID else { return }
                    self.handleTranscription(
                        finalText: text,
                        originalText: rawText,
                        postProcessingEnabled: postProcessingEnabled
                    )
                    self.completeRecordingProcessing()
                }
            } catch {
                if error is CancellationError {
                    sorenoLog("Transcription cancelled")
                    return
                }
                sorenoLog("Transcription ERROR: \(error)")
                await MainActor.run {
                    guard self.activeProcessingID == processingID else { return }
                    if self.shouldSuppressTranscriptionError(error) {
                        sorenoLog("Suppressing short/invalid audio transcription error")
                    } else {
                        self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                    }
                    self.completeRecordingProcessing()
                }
            }
        }
    }

    private func reconcileRecordingPresentation() {
        hotkeyManager.syncActiveState(isRecording)
        if (isReadAloudActive || isStartingReadAloud) && !isRecording && !isRecordingProcessing {
            return
        }

        if isRecording {
            RecordingPillWindow.shared.showRecording()
        } else if isRecordingProcessing {
            RecordingPillWindow.shared.showProcessing()
        } else {
            RecordingPillWindow.shared.hide()
        }
    }

    private func completeRecordingProcessing() {
        processingTask = nil
        isRecordingProcessing = false
        if !isReadAloudActive && !isStartingReadAloud {
            statusText = "Ready"
        }
        hotkeyManager.syncActiveState(false)
        reconcileRecordingPresentation()
    }

    func cancelProcessing() {
        guard isRecordingProcessing else { return }
        sorenoLog("Cancelling in-flight transcription/post-processing")
        activeProcessingID = UUID()
        processingTask?.cancel()
        processingTask = nil
        errorMessage = nil
        isRecordingProcessing = false
        statusText = "Ready"
        hotkeyManager.syncActiveState(false)
        reconcileRecordingPresentation()
    }

    private func handleAudioCaptureFailure(_ error: Error) {
        sorenoLog("Audio capture recovery failure: \(error.localizedDescription)")
        stopLiveSubtitles()
        isRecording = false
        isRecordingProcessing = false
        statusText = "Ready"
        hotkeyManager.syncActiveState(false)
        reconcileRecordingPresentation()
        errorMessage = "Recording stopped because the audio input changed. Try again."
    }

    private func shouldSuppressTranscriptionError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("invalid audio data")
            || message.contains("at least one second")
            || message.contains("audio too short")
            || message.contains("empty audio")
    }

    private func transcribeWithLanguageBackend(_ samples: [Float]) async throws -> String {
        if shouldUseWhisperBridge(), let bridge = whisperBridgeService {
            do {
                let response = try await bridge.transcribe(
                    audioData: samples,
                    sampleRate: config.sampleRate,
                    languageHint: currentLanguageHint()
                )
                sorenoLog(
                    "WhisperBridgeService: backend=\(response.backend ?? "unknown") detected_language=\(response.detectedLanguage ?? "unknown")"
                )
                return response.text
            } catch {
                if error is CancellationError {
                    throw error
                }
                sorenoLog("WhisperBridgeService failed: \(error.localizedDescription)")
                if whisperService.isLoaded {
                    sorenoLog("Falling back to Parakeet after Whisper bridge failure")
                    return try await whisperService.transcribe(audioData: samples)
                }
                throw error
            }
        }

        if !whisperService.isLoaded {
            await configureTranscriptionBackend(forceReload: true)
        }

        return try await whisperService.transcribe(audioData: samples)
    }

    private func configureTranscriptionBackend(forceReload: Bool) async {
        if isConfiguringTranscriptionBackend {
            return
        }
        if isModelLoading && !forceReload {
            return
        }

        isConfiguringTranscriptionBackend = true
        defer { isConfiguringTranscriptionBackend = false }

        let shouldUseWhisper = shouldUseWhisperBridge()

        if shouldUseWhisper {
            if whisperBridgeService == nil {
                sorenoLog("Whisper bridge requested but unavailable; using Parakeet fallback")
            } else {
                if whisperService.isLoaded {
                    whisperService.unloadModel()
                }
                isModelLoading = false
                isModelLoaded = true
                statusText = "Ready"
                return
            }
        }

        if whisperService.isLoaded && !forceReload {
            isModelLoading = false
            isModelLoaded = true
            if statusText == "Initializing..." || statusText == "Loading speech-to-text..." {
                statusText = "Ready"
            }
            return
        }

        statusText = "Loading speech-to-text..."
        isModelLoading = true
        do {
            sorenoLog("Loading Parakeet TDT 0.6B v2 model (auto-downloads on first run)...")
            try await whisperService.loadModel()
            isModelLoaded = true
            isModelLoading = false
            statusText = "Ready"
            sorenoLog("Parakeet v2 model loaded — Ready!")
        } catch {
            isModelLoading = false
            errorMessage = "Failed to load model: \(error.localizedDescription)"
            statusText = "Error"
            sorenoLog("ERROR loading model: \(error)")
        }
    }

    private func shouldUseWhisperBridge() -> Bool {
        ProductFlags.supportsMultiLanguage && config.isMultiLanguageSTTEnabled && !config.effectiveSpeechLanguage.isEnglish
    }

    private func currentLanguageHint() -> String? {
        config.effectiveSpeechLanguage.localeCode
    }

    private var isSmartPostProcessingAvailable: Bool {
        ProductFlags.smartPostProcessingEnabled
    }

    private func sanitizedDictionaryPairs() -> [PostProcessingPair] {
        config.customDictionaryEntries.compactMap {
            let source = $0.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = $0.correction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeCorrectionTerm(source), isSafeCorrectionTerm(target) else {
                return nil
            }
            return PostProcessingPair(source: source, target: target)
        }
    }

    private func sanitizedCorrectionMemoryPairs() -> [PostProcessingPair] {
        let pairs = config.correctionMemoryEntries.compactMap { entry -> PostProcessingPair? in
            let source = entry.misrecognized.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = entry.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeCorrectionTerm(source), isSafeCorrectionTerm(target) else {
                return nil
            }
            return PostProcessingPair(source: source, target: target)
        }

        return Array(pairs.suffix(80))
    }

    private func isSafeCorrectionTerm(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 140 else { return false }
        let lowered = value.lowercased()
        let blockedTokens = [
            "soreno user:",
            "user profile",
            "system prompt",
            "custom dictionary",
            "correction memory",
        ]

        if blockedTokens.contains(where: { lowered.contains($0) }) {
            return false
        }

        return !value.contains("\n")
    }

    private func pruneUnsafePostProcessingEntriesIfNeeded() {
        let safeDictionary = config.customDictionaryEntries.filter {
            isSafeCorrectionTerm($0.spoken.trimmingCharacters(in: .whitespacesAndNewlines))
                && isSafeCorrectionTerm($0.correction.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if safeDictionary.count != config.customDictionaryEntries.count {
            sorenoLog("Pruning unsafe custom dictionary entries (\(config.customDictionaryEntries.count - safeDictionary.count) removed)")
            config.customDictionaryEntries = safeDictionary
        }

        let safeMemory = config.correctionMemoryEntries.filter {
            isSafeCorrectionTerm($0.misrecognized.trimmingCharacters(in: .whitespacesAndNewlines))
                && isSafeCorrectionTerm($0.corrected.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if safeMemory.count != config.correctionMemoryEntries.count {
            sorenoLog("Pruning unsafe correction memory entries (\(config.correctionMemoryEntries.count - safeMemory.count) removed)")
            config.correctionMemoryEntries = safeMemory
        }
    }

    private func startLiveSubtitles() {
        liveSubtitleTask?.cancel()
        RecordingPillWindow.shared.updateSubtitleWords([])

        liveSubtitleTask = Task { [weak self] in
            guard let self else { return }
            var lastRendered = ""

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard isRecording else { break }

                let windowSamples = audioCaptureService.recentCapturedSamples(limit: 48_000)
                guard windowSamples.count >= 16_000 else { continue }

                do {
                    let partial = try await transcribeWithLanguageBackend(windowSamples)
                    let words = Self.extractRollingSubtitleWords(from: partial, limit: 160)
                    guard !words.isEmpty else { continue }

                    let signature = words.joined(separator: " ")
                    guard signature != lastRendered else { continue }

                    lastRendered = signature

                    self.liveSubtitleWords = words
                    RecordingPillWindow.shared.updateSubtitleWords(words)
                } catch {
                    continue
                }
            }
        }
    }

    private func stopLiveSubtitles() {
        liveSubtitleTask?.cancel()
        liveSubtitleTask = nil

        withAnimation(.easeOut(duration: 0.15)) {
            liveSubtitleWords = []
        }
        RecordingPillWindow.shared.updateSubtitleWords([])
    }

    private static func extractRollingSubtitleWords(from text: String, limit: Int) -> [String] {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { token in
                token.trimmingCharacters(in: .punctuationCharacters)
            }
            .filter { !$0.isEmpty }

        return Array(words.suffix(limit))
    }

    private func reactivateExternalAppForSelectionIfNeeded() async {
        guard let bundleID = Bundle.main.bundleIdentifier,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
              let externalApp = lastNonSorenoApplication,
              !externalApp.isTerminated
        else {
            return
        }

        externalApp.activate(options: [])
        try? await Task.sleep(nanoseconds: 180_000_000)
    }

    func readSelectedTextAloud() {
        Task { @MainActor in
            do {
                await reactivateExternalAppForSelectionIfNeeded()
                guard let capturedText = textInserter.captureSelectedText() else {
                    throw TextToSpeechError.emptyText
                }

                sorenoLog("Read aloud: captured text via \(capturedText.source.rawValue)")
                try await speakTextAloud(capturedText.text, status: "Reading selection...")
            } catch {
                errorMessage = "Read aloud failed: \(error.localizedDescription)"
                statusText = "Ready"
                sorenoLog("TTS ERROR: \(error.localizedDescription)")
            }
        }
    }

    func readClipboardAloud() {
        Task { @MainActor in
            do {
                guard let capturedText = textInserter.captureClipboardText() else {
                    throw TextToSpeechError.emptyText
                }

                sorenoLog("Read aloud: captured text via \(capturedText.source.rawValue)")
                try await speakTextAloud(capturedText.text, status: "Reading clipboard...")
            } catch {
                errorMessage = "Read clipboard failed: \(error.localizedDescription)"
                statusText = "Ready"
                sorenoLog("TTS ERROR: \(error.localizedDescription)")
            }
        }
    }

    func stopReadAloud() {
        textToSpeechService.stop()
        activeReadAloudText = ""
        isManagingReadAloudStatus = false
        statusText = "Ready"
        if isRecording || isRecordingProcessing {
            reconcileRecordingPresentation()
        } else {
            RecordingPillWindow.shared.hide()
        }
    }

    func pauseReadAloud() {
        textToSpeechService.pause()
    }

    func resumeReadAloud() {
        textToSpeechService.resume()
    }

    func skipReadAloud(by seconds: TimeInterval) {
        textToSpeechService.skip(by: seconds)
    }

    func setReadAloudRate(_ rate: Double) {
        config.readAloudRate = min(max(rate, AppConfig.readAloudRateRange.lowerBound), AppConfig.readAloudRateRange.upperBound)
    }

    func beginReadAloudScrub() {
        shouldResumeReadAloudAfterScrub = isReadAloudPlaying && !isReadAloudPaused
        if shouldResumeReadAloudAfterScrub {
            pauseReadAloud()
        }
    }

    func endReadAloudScrub(at progress: Double) {
        let shouldPlayAfterScrub = shouldResumeReadAloudAfterScrub
        shouldResumeReadAloudAfterScrub = false
        textToSpeechService.seek(to: progress, shouldPlay: shouldPlayAfterScrub)
    }

    func toggleReadAloudPause() {
        if isReadAloudPaused {
            resumeReadAloud()
        } else {
            pauseReadAloud()
        }
    }

    func previewReadAloudVoice(_ voiceIdentifier: String, rate: Double? = nil) {
        Task { @MainActor in
            do {
                try await speakTextAloud(
                    Self.previewText(for: config.effectiveSpeechLanguage),
                    status: "Previewing voice...",
                    voiceIdentifierOverride: voiceIdentifier,
                    rateOverride: rate
                )
            } catch {
                errorMessage = "Voice preview failed: \(error.localizedDescription)"
                statusText = "Ready"
                sorenoLog("TTS PREVIEW ERROR: \(error.localizedDescription)")
            }
        }
    }

    func explainHoveredElementAloud() {
        Task { @MainActor in
            do {
                await reactivateExternalAppForSelectionIfNeeded()
                let snapshot = try hoveredElementInspector.captureHoveredElement()
                sorenoLog(
                    "UI explain: app=\(snapshot.appName) role=\(snapshot.role ?? "unknown") title=\(snapshot.title ?? "unknown")"
                )

                statusText = "Explaining hovered item..."
                errorMessage = nil

                let explanation: String
                if let uiElementExplanationService {
                    explanation = await uiElementExplanationService.explainOrFallback(
                        snapshot: snapshot,
                        context: UIElementExplanationContext(
                            profileName: "Default",
                            systemPrompt: config.userProfilePrompt
                        )
                    )
                } else {
                    explanation = snapshot.fallbackExplanation
                }

                try await speakTextAloud(explanation, status: "Explaining hovered item...")
            } catch {
                errorMessage = "Explain hovered item failed: \(error.localizedDescription)"
                statusText = "Ready"
                sorenoLog("UI explain ERROR: \(error.localizedDescription)")
            }
        }
    }

    private func speakTextAloud(
        _ text: String,
        status: String,
        voiceIdentifierOverride: String? = nil,
        rateOverride: Double? = nil
    ) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw TextToSpeechError.emptyText
        }

        errorMessage = nil
        statusText = status
        activeReadAloudStatusText = status
        activeReadAloudText = trimmedText
        isManagingReadAloudStatus = true
        isStartingReadAloud = true
        RecordingPillWindow.shared.showReadAloud(text: trimmedText, rate: config.readAloudRate)
        defer { isStartingReadAloud = false }

        let selectedVoiceIdentifier = voiceIdentifierOverride ?? config.readAloudVoiceIdentifier
        let wantsEnhancedVoice = selectedVoiceIdentifier == AppConfig.enhancedReadAloudVoiceIdentifier
        let preferEnhanced = ProductFlags.supportsOfflineReadAloudVoice && config.isEnhancedTTSEnabled && wantsEnhancedVoice
        let appleVoiceIdentifier: String? = {
            guard selectedVoiceIdentifier != AppConfig.enhancedReadAloudVoiceIdentifier,
                  selectedVoiceIdentifier != AppConfig.systemDefaultReadAloudVoiceIdentifier
            else {
                return nil
            }

            return selectedVoiceIdentifier
        }()
        let piperPath = modelFeatureManager.installedModelPath(for: .piperEnhancedTTS)
        let canUseEnhanced = preferEnhanced && piperPath != nil

        if !canUseEnhanced && !config.isAppleTTSEnabled {
            throw TextToSpeechError.piperModelUnavailable
        }

        do {
            do {
                let backend = try await textToSpeechService.speak(
                    text: trimmedText,
                    language: config.effectiveSpeechLanguage,
                    preferEnhanced: canUseEnhanced,
                    piperModelPath: piperPath,
                    appleVoiceIdentifier: appleVoiceIdentifier,
                    rateMultiplier: rateOverride ?? config.readAloudRate
                )
                lastReadAloudEngineDescription = backend.debugDescription
                sorenoLog("TTS backend selected: \(backend.debugDescription)")
            } catch let error as TextToSpeechError where canUseEnhanced {
                switch error {
                case .piperExecutableMissing, .piperVoiceMissing, .piperSynthesisFailed:
                    let backend = try await textToSpeechService.speak(
                        text: trimmedText,
                        language: config.effectiveSpeechLanguage,
                        preferEnhanced: false,
                        piperModelPath: nil,
                        appleVoiceIdentifier: appleVoiceIdentifier,
                        rateMultiplier: rateOverride ?? config.readAloudRate
                    )
                    lastReadAloudEngineDescription = backend.debugDescription
                    sorenoLog("TTS backend fallback selected: \(backend.debugDescription)")
                case .emptyText, .piperModelUnavailable:
                    throw error
                }
            }
        } catch {
            activeReadAloudText = ""
            isManagingReadAloudStatus = false
            statusText = "Ready"
            if !isRecording && !isRecordingProcessing {
                RecordingPillWindow.shared.hide()
            }
            throw error
        }
    }

    private static func previewText(for language: AppConfig.AppLanguage) -> String {
        switch language {
        case .arabic:
            return "مرحبا، هذا معاينة لصوت القراءة في سورينو."
        case .turkish:
            return "Merhaba, bu Soreno sesli okuma onlemesidir."
        case .spanish:
            return "Hola, esta es una vista previa de la voz de lectura de Soreno."
        case .french:
            return "Bonjour, ceci est un apercu de la voix de lecture de Soreno."
        case .german:
            return "Hallo, das ist eine Horprobe der Soreno Vorlesestimme."
        default:
            return "Hello, this is a preview of Soreno's read-aloud voice."
        }
    }

    private func handleReadAloudPlaybackStateChange(_ state: TextToSpeechPlaybackState) {
        switch state {
        case .idle:
            isReadAloudPlaying = false
            isReadAloudPaused = false
            guard !isStartingReadAloud else {
                return
            }
            if isRecording || isRecordingProcessing {
                reconcileRecordingPresentation()
            } else {
                RecordingPillWindow.shared.hide()
            }
            if isManagingReadAloudStatus {
                isManagingReadAloudStatus = false
                activeReadAloudText = ""
                if !isRecording && !isRecordingProcessing {
                    statusText = "Ready"
                }
            }
        case .speaking:
            isReadAloudPlaying = true
            isReadAloudPaused = false
            RecordingPillWindow.shared.ensureReadAloudVisible(text: activeReadAloudText)
            RecordingPillWindow.shared.setReadAloudPaused(false)
            if isManagingReadAloudStatus {
                statusText = activeReadAloudStatusText
            }
        case .paused:
            isReadAloudPlaying = false
            isReadAloudPaused = true
            RecordingPillWindow.shared.ensureReadAloudVisible(text: activeReadAloudText)
            RecordingPillWindow.shared.setReadAloudPaused(true)
            if isManagingReadAloudStatus {
                statusText = "Reading paused"
            }
        }
    }

    private func handleReadAloudPlaybackProgress(_ progress: TextToSpeechProgress) {
        RecordingPillWindow.shared.updateReadAloudProgress(progress, isPaused: isReadAloudPaused)
    }

    // MARK: - Transcription

    private func handleTranscription(finalText: String, originalText: String, postProcessingEnabled: Bool) {
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            sorenoLog("Transcription was empty, skipping")
            statusText = "Ready"
            return
        }

        sorenoLog("Transcription: '\(trimmed)'")
        lastTranscription = trimmed
        transcriptions.append(
            AppConfig.TranscriptHistoryEntry(
                finalText: trimmed,
                originalText: originalText.trimmingCharacters(in: .whitespacesAndNewlines),
                postProcessingEnabled: postProcessingEnabled
            )
        )
        statusText = "Ready"

        // Keep bounded and persisted
        if transcriptions.count > 20 {
            transcriptions.removeFirst(transcriptions.count - 20)
        }
        config.recentTranscriptHistoryEntries = transcriptions
        config.recentTranscriptParagraphs = transcriptions.map(\.finalText)

        // Insert text into the active app while keeping the final transcript on the clipboard.
        sorenoLog("Inserting text: '\(trimmed)'")
        textInserter.insertText(trimmed, finalClipboardText: trimmed)
        flashCopiedToClipboardState()
    }

    // MARK: - Clipboard Copy (from history)

    /// The last 3 transcriptions, most recent first.
    var recentTranscriptions: [String] {
        Array(transcriptions.suffix(3).reversed().map(\.finalText))
    }

    /// The latest 20 transcript paragraphs, most recent first.
    var paragraphHistory: [AppConfig.TranscriptHistoryEntry] {
        Array(transcriptions.suffix(20).reversed())
    }

    func clearParagraphHistory() {
        transcriptions.removeAll()
        config.recentTranscriptParagraphs = []
        config.recentTranscriptHistoryEntries = []
    }

    var shouldShowFirstLaunchOnboarding: Bool {
        !config.hasCompletedFirstLaunchOnboarding
    }

    func completeFirstLaunchOnboarding() {
        config.hasCompletedFirstLaunchOnboarding = true
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sorenoLog("Copied to clipboard: '\(text)'")

        flashCopiedToClipboardState()
    }

    private func flashCopiedToClipboardState() {
        copiedToClipboard = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copiedToClipboard = false
        }
    }
}
