import Foundation

struct PiperBridgeSynthesisResult: Decodable {
    let audioPath: String
    let backend: String?
    let voice: String?

    enum CodingKeys: String, CodingKey {
        case audioPath = "audio_path"
        case backend
        case voice
    }
}

enum PiperPythonRuntimeError: LocalizedError {
    case bootstrapFailed(String)

    var errorDescription: String? {
        switch self {
        case .bootstrapFailed(let message):
            return "Enhanced text-to-speech runtime setup failed: \(message)"
        }
    }
}

actor PiperPythonRuntimeManager {
    static let shared = PiperPythonRuntimeManager()

    private var cachedPythonPath: String?

    func ensureRuntimeReady() async throws -> String {
        if let cachedPythonPath, FileManager.default.isExecutableFile(atPath: cachedPythonPath) {
            return cachedPythonPath
        }

        let pythonPath = try await Task.detached(priority: .userInitiated) {
            try Self.prepareRuntime()
        }.value

        cachedPythonPath = pythonPath
        return pythonPath
    }

    private static func prepareRuntime() throws -> String {
        let fileManager = FileManager.default
        let venvRoot = try runtimeRootURL()
        let venvPython = venvRoot.appendingPathComponent("bin/python3", isDirectory: false).path

        if runtimeLooksReady(pythonPath: venvPython) {
            return venvPython
        }

        let bootstrapPython = PythonBridgeClient.detectPythonExecutable()
        try fileManager.createDirectory(at: venvRoot.deletingLastPathComponent(), withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: venvPython) {
            try runProcess(
                executablePath: bootstrapPython,
                arguments: ["-m", "venv", venvRoot.path],
                label: "create Piper runtime venv"
            )
        }

        try runProcess(
            executablePath: venvPython,
            arguments: ["-m", "pip", "install", "--upgrade", "pip"],
            label: "upgrade Piper runtime pip"
        )
        try runProcess(
            executablePath: venvPython,
            arguments: ["-m", "pip", "install", "piper-tts"],
            label: "install Piper runtime package"
        )

        guard runtimeLooksReady(pythonPath: venvPython) else {
            throw PiperPythonRuntimeError.bootstrapFailed("Python package import check failed after installation")
        }

        return venvPython
    }

    private static func runtimeRootURL() throws -> URL {
        let appSupportRoot = try LocalModelBootstrap.modelsRootURL().deletingLastPathComponent()
        return appSupportRoot.appendingPathComponent("Python/piper-venv", isDirectory: true)
    }

    private static func runtimeLooksReady(pythonPath: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", "from piper import PiperVoice; import onnxruntime; print('ok')"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runProcess(executablePath: String, arguments: [String], label: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw PiperPythonRuntimeError.bootstrapFailed("\(label) launch failed: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let details = [stderr, stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "Unknown failure"
            throw PiperPythonRuntimeError.bootstrapFailed("\(label) failed: \(details)")
        }
    }
}

final class PiperPythonSynthesisService {
    private let scriptPath: URL
    private var bridgeClient: PythonBridgeClient?
    private var bridgePythonPath: String?

    init(scriptPath: URL) {
        self.scriptPath = scriptPath
    }

    func synthesize(text: String, modelRoot: URL) async throws -> (wavURL: URL, backend: TextToSpeechBackend) {
        let pythonPath = try await PiperPythonRuntimeManager.shared.ensureRuntimeReady()
        if bridgeClient == nil || bridgePythonPath != pythonPath {
            bridgeClient = PythonBridgeClient(scriptPath: scriptPath, executablePath: pythonPath)
            bridgePythonPath = pythonPath
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("soreno-piper-\(UUID().uuidString).wav")

        let request = PythonBridgeRequest(
            operation: "synthesize_tts",
            modelPath: modelRoot.path,
            text: text,
            audioPath: outputURL.path,
            language: nil,
            profileName: nil,
            systemPrompt: nil,
            customDictionary: nil,
            correctionMemory: nil
        )

        guard let bridgeClient else {
            throw PiperPythonRuntimeError.bootstrapFailed("bridge client was not initialized")
        }

        let response: PiperBridgeSynthesisResult = try await bridgeClient.call(request, timeout: 90)
        let voiceModel = response.voice ?? Self.defaultVoiceName(from: modelRoot)
        let backendLabel = response.backend ?? "piper-tts"
        return (
            wavURL: URL(fileURLWithPath: response.audioPath),
            backend: .enhancedPiper(voiceModel: voiceModel, runtime: backendLabel)
        )
    }

    private static func defaultVoiceName(from modelRoot: URL) -> String {
        if modelRoot.pathExtension.lowercased() == "onnx" {
            return modelRoot.deletingPathExtension().lastPathComponent
        }

        return modelRoot.lastPathComponent
    }
}
