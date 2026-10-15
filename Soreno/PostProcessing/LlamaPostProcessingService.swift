import Foundation

struct PostProcessedTranscript: Decodable {
    let text: String
}

struct PostProcessingPair {
    let source: String
    let target: String
}

struct PostProcessingContext {
    let language: String?
    let profileName: String
    let systemPrompt: String
    let customDictionary: [PostProcessingPair]
    let correctionMemory: [PostProcessingPair]
}

final class LlamaPostProcessingService {
    private let bridgeClient: PythonBridgeClient
    private let modelPath: URL
    private let timeout: TimeInterval

    init(bridgeClient: PythonBridgeClient, modelPath: URL, timeout: TimeInterval = 12) {
        self.bridgeClient = bridgeClient
        self.modelPath = modelPath
        self.timeout = timeout
    }

    func process(rawTranscript: String, context: PostProcessingContext) async throws -> String {
        let dictionaryEntries = context.customDictionary
            .filter {
                !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map {
                PythonBridgeDictionaryEntry(
                    spoken: $0.source.trimmingCharacters(in: .whitespacesAndNewlines),
                    replacement: $0.target.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

        let memoryEntries = context.correctionMemory
            .filter {
                !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map {
                PythonBridgeCorrectionEntry(
                    original: $0.source.trimmingCharacters(in: .whitespacesAndNewlines),
                    corrected: $0.target.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

        let request = PythonBridgeRequest(
            operation: "post_process",
            modelPath: modelPath.path,
            text: rawTranscript,
            audioPath: nil,
            language: context.language,
            profileName: context.profileName,
            systemPrompt: context.systemPrompt,
            customDictionary: dictionaryEntries,
            correctionMemory: memoryEntries
        )

        let response: PostProcessedTranscript = try await bridgeClient.call(request, timeout: timeout)
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func processOrFallback(rawTranscript: String, context: PostProcessingContext) async -> String {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawTranscript }

        do {
            let processed = try await process(rawTranscript: rawTranscript, context: context)
            let cleaned = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                sorenoLog("post_process fallback=raw reason=empty_model_output")
                return rawTranscript
            }
            if !isSafeFormattingOnlyRewrite(original: trimmed, candidate: cleaned) {
                sorenoLog("post_process fallback=raw reason=unsafe_rewrite")
                return rawTranscript
            }
            return cleaned
        } catch {
            sorenoLog("post_process fallback=raw reason=\(error.localizedDescription)")
            return rawTranscript
        }
    }

    private func isSafeFormattingOnlyRewrite(original: String, candidate: String) -> Bool {
        let originalTokens = normalizedTokens(from: original)
        let candidateTokens = normalizedTokens(from: candidate)

        guard !originalTokens.isEmpty, !candidateTokens.isEmpty else {
            return candidate == original
        }

        let originalSet = Set(originalTokens)
        let candidateSet = Set(candidateTokens)
        let sharedCount = originalSet.intersection(candidateSet).count
        let coverage = Double(sharedCount) / Double(originalSet.count)
        let novelty = Double(candidateSet.subtracting(originalSet).count) / Double(candidateSet.count)

        return coverage >= 0.8 && novelty <= 0.2
    }

    private func normalizedTokens(from text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
