import Foundation
import FluidAudio

/// Wraps FluidAudio (Parakeet TDT 0.6B v2) for speech-to-text transcription.
/// Uses the English-only v2 model for best accuracy on Apple Neural Engine.
final class WhisperService {
    private var asrManager: AsrManager?

    /// Load the Parakeet v2 model from the local cache (no network).
    /// Run `./download-models.sh` first to fetch the models.
    func loadModel() async throws {
        let totalStart = CFAbsoluteTimeGetCurrent()

        let cacheDir = AsrModels.defaultCacheDirectory(for: .v2)
        sorenoLog("WhisperService: loading Parakeet TDT 0.6B v2 from \(cacheDir.path)...")

        guard AsrModels.modelsExist(at: cacheDir, version: .v2) else {
            throw TranscriptionError.modelsNotDownloaded
        }

        let models = try await AsrModels.load(from: cacheDir, version: .v2)
        sorenoLog("WhisperService: CoreML models compiled in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - totalStart))s")

        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)

        asrManager = asr

        let totalElapsed = CFAbsoluteTimeGetCurrent() - totalStart
        sorenoLog("WhisperService: model loaded successfully! Total: \(String(format: "%.2f", totalElapsed))s")
    }

    /// Transcribe 16kHz mono Float32 audio data to text.
    func transcribe(audioData: [Float]) async throws -> String {
        guard let asr = asrManager else {
            throw TranscriptionError.modelNotLoaded
        }

        sorenoLog("WhisperService: transcribing \(audioData.count) samples (\(String(format: "%.1f", Float(audioData.count) / 16000.0))s)...")
        let result = try await asr.transcribe(audioData, source: .microphone)
        sorenoLog("WhisperService: result = '\(result.text)' (confidence: \(String(format: "%.2f", result.confidence)), RTFx: \(String(format: "%.0f", result.rtfx))x)")
        return result.text
    }

    var isLoaded: Bool {
        asrManager != nil
    }

    func unloadModel() {
        asrManager = nil
        sorenoLog("WhisperService: Parakeet model unloaded")
    }

    enum TranscriptionError: Error, LocalizedError {
        case modelNotLoaded
        case modelsNotDownloaded

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "Parakeet model is not loaded"
            case .modelsNotDownloaded:
                return "Models not found. Run ./download-models.sh first."
            }
        }
    }
}
