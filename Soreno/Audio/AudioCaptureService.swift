import AVFoundation
import Accelerate
import Foundation

/// Captures microphone audio using AVAudioEngine and provides 16kHz mono Float32 samples.
final class AudioCaptureService {
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var isRunning = false
    private var isRestarting = false

    /// The target format: 16kHz mono Float32.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Audio format converter (proper polyphase resampling).
    private var converter: AVAudioConverter?

    /// High-pass filter state for removing low-frequency rumble/hum.
    private var hpPrevInput: Float = 0
    private var hpPrevOutput: Float = 0

    private var chunkCount = 0
    private let capturedSamplesLock = NSLock()
    private var capturedSamples: [Float] = []

    /// Current audio level (RMS) — updated on every chunk from audio thread.
    var onLevel: ((Float) -> Void)?

    /// Raw PCM buffer callback — forwards 16kHz mono buffers to the streaming ASR manager.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called if a running recording session cannot recover from an audio engine reset.
    var onCaptureFailure: ((Error) -> Void)?

    var isCapturing: Bool {
        isRunning
    }

    deinit {
        teardownEngine()
    }

    /// Compute high-pass filter coefficient for a given cutoff frequency.
    /// Single-pole filter: y[n] = alpha * (y[n-1] + x[n] - x[n-1])
    private static func highPassAlpha(cutoff: Float, sampleRate: Float) -> Float {
        let rc = 1.0 / (2.0 * Float.pi * cutoff)
        let dt = 1.0 / sampleRate
        return rc / (rc + dt)
    }

    /// Start capturing audio. Forwards buffers via `onBuffer` and levels via `onLevel`.
    func start() throws {
        guard !isRunning else { return }

        resetCapturedSamples()
        hpPrevInput = 0
        hpPrevOutput = 0
        chunkCount = 0
        isRestarting = false

        try configureAndStartEngine()
        isRunning = true
        sorenoLog("AVAudioEngine started successfully")
    }

    func stop() {
        guard isRunning || engine != nil else { return }
        teardownEngine()
        isRunning = false
        isRestarting = false
        sorenoLog("Audio capture stopped after \(chunkCount) chunks")
    }

    func consumeCapturedSamples() -> [Float] {
        capturedSamplesLock.lock()
        defer { capturedSamplesLock.unlock() }

        let samples = capturedSamples
        capturedSamples.removeAll(keepingCapacity: false)
        return samples
    }

    func recentCapturedSamples(limit: Int) -> [Float] {
        capturedSamplesLock.lock()
        defer { capturedSamplesLock.unlock() }
        return Array(capturedSamples.suffix(limit))
    }

    private func resetCapturedSamples() {
        capturedSamplesLock.lock()
        capturedSamples.removeAll(keepingCapacity: false)
        capturedSamplesLock.unlock()
    }

    private func appendCapturedSamples(_ samples: [Float]) {
        capturedSamplesLock.lock()
        capturedSamples.append(contentsOf: samples)
        capturedSamplesLock.unlock()
    }

    private func configureAndStartEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        observeConfigurationChanges(for: engine)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        sorenoLog("Audio input format: \(inputFormat)")
        sorenoLog("Audio target format: \(targetFormat)")

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        conv.sampleRateConverterQuality = .max
        converter = conv

        let hpAlpha = Self.highPassAlpha(cutoff: 80, sampleRate: 16000)
        sorenoLog("Mic sample rate: \(inputFormat.sampleRate), channels: \(inputFormat.channelCount)")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }

            let ratio = inputFormat.sampleRate / 16000.0
            let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) / ratio)
            guard outputFrames > 0 else { return }

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: outputFrames) else { return }

            var error: NSError?
            var consumed = false
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if let error {
                if self.chunkCount == 0 {
                    sorenoLog("Converter error: \(error)")
                }
                return
            }

            self.onBuffer?(outputBuffer)

            let frameLength = Int(outputBuffer.frameLength)
            guard frameLength > 0, let channelData = outputBuffer.floatChannelData else { return }

            var samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

            var prevIn = self.hpPrevInput
            var prevOut = self.hpPrevOutput
            for i in 0..<samples.count {
                let x = samples[i]
                prevOut = hpAlpha * (prevOut + x - prevIn)
                prevIn = x
                samples[i] = prevOut
            }
            self.hpPrevInput = prevIn
            self.hpPrevOutput = prevOut

            self.appendCapturedSamples(samples)

            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
            self.onLevel?(rms)

            self.chunkCount += 1
            if self.chunkCount == 1 {
                sorenoLog("First audio chunk: \(samples.count) samples from \(buffer.frameLength) input frames")
            }
            if self.chunkCount % 100 == 0 {
                sorenoLog("Audio chunk #\(self.chunkCount): \(samples.count) samples, RMS=\(String(format: "%.4f", rms))")
            }
        }

        engine.prepare()
        try engine.start()
    }

    private func observeConfigurationChanges(for engine: AVAudioEngine) {
        removeConfigurationObserver()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartIfNeeded(reason: "audio input configuration changed")
        }
    }

    private func removeConfigurationObserver() {
        guard let configurationObserver else { return }
        NotificationCenter.default.removeObserver(configurationObserver)
        self.configurationObserver = nil
    }

    private func restartIfNeeded(reason: String) {
        guard isRunning, !isRestarting else { return }
        isRestarting = true
        sorenoLog("Restarting audio capture: \(reason)")

        do {
            teardownEngine()
            hpPrevInput = 0
            hpPrevOutput = 0
            try configureAndStartEngine()
            isRestarting = false
            sorenoLog("Audio capture restart completed")
        } catch {
            isRunning = false
            isRestarting = false
            teardownEngine()
            let wrappedError = AudioCaptureError.restartFailed(reason: reason, underlying: error.localizedDescription)
            sorenoLog("Audio capture restart failed: \(wrappedError.localizedDescription)")
            onCaptureFailure?(wrappedError)
        }
    }

    private func teardownEngine() {
        removeConfigurationObserver()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        self.engine = nil
        converter = nil
    }

    enum AudioCaptureError: Error, LocalizedError {
        case converterCreationFailed
        case restartFailed(reason: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .converterCreationFailed:
                return "Failed to create audio format converter"
            case .restartFailed(let reason, let underlying):
                return "Audio capture could not recover after \(reason): \(underlying)"
            }
        }
    }
}
