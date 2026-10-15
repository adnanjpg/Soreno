import Foundation

struct UIElementExplanationResult: Decodable {
    let text: String
}

struct UIElementExplanationContext {
    let profileName: String
    let systemPrompt: String
}

final class UIElementExplanationService {
    private let bridgeClient: PythonBridgeClient
    private let modelPath: URL
    private let timeout: TimeInterval

    init(bridgeClient: PythonBridgeClient, modelPath: URL, timeout: TimeInterval = 12) {
        self.bridgeClient = bridgeClient
        self.modelPath = modelPath
        self.timeout = timeout
    }

    func explain(snapshot: HoveredElementSnapshot, context: UIElementExplanationContext) async throws -> String {
        let request = PythonBridgeRequest(
            operation: "explain_ui_element",
            modelPath: modelPath.path,
            text: snapshot.promptContext,
            audioPath: nil,
            language: nil,
            profileName: context.profileName,
            systemPrompt: context.systemPrompt,
            customDictionary: nil,
            correctionMemory: nil
        )

        let response: UIElementExplanationResult = try await bridgeClient.call(request, timeout: timeout)
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func explainOrFallback(snapshot: HoveredElementSnapshot, context: UIElementExplanationContext) async -> String {
        do {
            let explanation = try await explain(snapshot: snapshot, context: context)
            let trimmed = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                sorenoLog("ui_explain fallback=deterministic reason=empty_model_output")
                return snapshot.fallbackExplanation
            }
            return trimmed
        } catch {
            sorenoLog("ui_explain fallback=deterministic reason=\(error.localizedDescription)")
            return snapshot.fallbackExplanation
        }
    }
}
