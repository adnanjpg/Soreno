import Foundation

struct PythonBridgeRequest: Encodable {
    let operation: String
    let modelPath: String
    let text: String?
    let audioPath: String?
    let language: String?
    let profileName: String?
    let systemPrompt: String?
    let customDictionary: [PythonBridgeDictionaryEntry]?
    let correctionMemory: [PythonBridgeCorrectionEntry]?

    enum CodingKeys: String, CodingKey {
        case operation
        case modelPath = "model_path"
        case text
        case audioPath = "audio_path"
        case language
        case profileName = "profile_name"
        case systemPrompt = "system_prompt"
        case customDictionary = "custom_dictionary"
        case correctionMemory = "correction_memory"
    }
}

struct PythonBridgeDictionaryEntry: Encodable {
    let spoken: String
    let replacement: String
}

struct PythonBridgeCorrectionEntry: Encodable {
    let original: String
    let corrected: String
}

struct PythonBridgeResult<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
    let error: PythonBridgeErrorPayload?
}

struct PythonBridgeErrorPayload: Decodable {
    let code: String
    let message: String
    let details: String?
}

enum PythonBridgeError: LocalizedError {
    case runFailure(String)
    case timeout(TimeInterval)
    case terminated(Int32, String)
    case invalidResponse(String)
    case bridge(String, details: String?)

    var errorDescription: String? {
        switch self {
        case .runFailure(let msg):
            return "Python bridge launch failed: \(msg)"
        case .timeout(let timeout):
            return "Python bridge timed out after \(Int(timeout))s"
        case .terminated(let code, let stderr):
            return "Python bridge exited with code \(code): \(stderr)"
        case .invalidResponse(let message):
            return "Python bridge returned invalid response: \(message)"
        case .bridge(let message, _):
            return "Python bridge error: \(message)"
        }
    }
}

final class PythonBridgeClient {
    private let scriptPath: URL
    private let executablePath: String

    init(scriptPath: URL, executablePath: String? = nil) {
        self.scriptPath = scriptPath
        self.executablePath = executablePath ?? Self.detectPythonExecutable()
        sorenoLog("PythonBridgeClient: using interpreter at \(self.executablePath)")
    }

    func call<T: Decodable>(_ request: PythonBridgeRequest, timeout: TimeInterval) async throws -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let cancellationHandle = ProcessCancellationHandle()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [scriptPath.path]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let requestData = try JSONEncoder().encode(request)

        do {
            try process.run()
        } catch {
            throw PythonBridgeError.runFailure(error.localizedDescription)
        }
        cancellationHandle.set(process)

        stdinPipe.fileHandleForWriting.write(requestData)
        try? stdinPipe.fileHandleForWriting.close()

        return try await withTaskCancellationHandler {
            do {
                try await waitForExit(process: process, timeout: timeout)
                try Task.checkCancellation()
            } catch {
                if process.isRunning {
                    process.terminate()
                }
                if error is CancellationError {
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    sorenoLog("bridge_error operation=\(request.operation) reason=cancelled elapsed=\(String(format: "%.2f", elapsed))s")
                    throw error
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                sorenoLog("bridge_error operation=\(request.operation) reason=timeout elapsed=\(String(format: "%.2f", elapsed))s")
                throw error
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

            try Task.checkCancellation()

            guard process.terminationStatus == 0 else {
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                sorenoLog(
                    "bridge_error operation=\(request.operation) reason=terminated code=\(process.terminationStatus) elapsed=\(String(format: "%.2f", elapsed))s stderr=\(stderrString)"
                )
                throw PythonBridgeError.terminated(process.terminationStatus, stderrString)
            }

            let decoder = JSONDecoder()
            let envelope: PythonBridgeResult<T>
            do {
                envelope = try decoder.decode(PythonBridgeResult<T>.self, from: stdoutData)
            } catch {
                let rawOut = String(data: stdoutData, encoding: .utf8) ?? "<non-utf8>"
                throw PythonBridgeError.invalidResponse("decode failed: \(error.localizedDescription), output=\(rawOut)")
            }

            if let payload = envelope.error {
                sorenoLog(
                    "bridge_error operation=\(request.operation) reason=bridge code=\(payload.code) message=\(payload.message)"
                )
                throw PythonBridgeError.bridge(payload.message, details: payload.details)
            }

            guard envelope.ok, let result = envelope.result else {
                throw PythonBridgeError.invalidResponse("missing result payload")
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            sorenoLog("bridge_success operation=\(request.operation) elapsed=\(String(format: "%.2f", elapsed))s")
            return result
        } onCancel: {
            cancellationHandle.terminateIfRunning()
        }
    }

    private func waitForExit(process: Process, timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                process.waitUntilExit()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw PythonBridgeError.timeout(timeout)
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    static func detectPythonExecutable() -> String {
        let env = ProcessInfo.processInfo.environment
        if let fromEnv = env["SORENO_PYTHON"], isExecutableFile(fromEnv) {
            return fromEnv
        }
        if let fromLegacyEnv = env["LISTEN_PYTHON"], isExecutableFile(fromLegacyEnv) {
            return fromLegacyEnv
        }

        let candidates = [
            "\(NSHomeDirectory())/.soreno-venv/bin/python3",
            "\(NSHomeDirectory())/.listen-venv/bin/python3",
            "\(NSHomeDirectory())/.venv/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for path in candidates where isExecutableFile(path) {
            return path
        }

        return "/usr/bin/python3"
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

private final class ProcessCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminateIfRunning() {
        lock.lock()
        let process = self.process
        lock.unlock()

        guard let process, process.isRunning else { return }
        process.terminate()
    }
}
