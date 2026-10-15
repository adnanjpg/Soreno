import Foundation

struct NonEnglishTranscriptionResult: Decodable {
    let text: String
    let detectedLanguage: String?
    let backend: String?

    enum CodingKeys: String, CodingKey {
        case text
        case detectedLanguage = "detected_language"
        case backend
    }
}

final class WhisperBridgeService {
    private let bridgeClient: PythonBridgeClient
    private let modelPath: URL
    private let timeout: TimeInterval

    init(bridgeClient: PythonBridgeClient, modelPath: URL, timeout: TimeInterval = 45) {
        self.bridgeClient = bridgeClient
        self.modelPath = modelPath
        self.timeout = timeout
    }

    func transcribe(audioData: [Float], sampleRate: Int, languageHint: String?) async throws -> NonEnglishTranscriptionResult {
        let audioPath = try writeWavToTemp(audioData: audioData, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: audioPath) }

        let request = PythonBridgeRequest(
            operation: "transcribe_non_english",
            modelPath: modelPath.path,
            text: nil,
            audioPath: audioPath.path,
            language: languageHint,
            profileName: nil,
            systemPrompt: nil,
            customDictionary: nil,
            correctionMemory: nil
        )

        return try await bridgeClient.call(request, timeout: timeout)
    }

    private func writeWavToTemp(audioData: [Float], sampleRate: Int) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let fileURL = tmp.appendingPathComponent("soreno-non-english-\(UUID().uuidString).wav")

        var data = Data()
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)

        var pcm = Data(capacity: audioData.count * 2)
        for sample in audioData {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * Float(Int16.max))
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
        }

        let subchunk2Size = UInt32(pcm.count)
        let chunkSize = UInt32(36) + subchunk2Size

        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: chunkSize)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(contentsOf: UInt32(16))
        data.append(contentsOf: UInt16(1))
        data.append(contentsOf: numChannels)
        data.append(contentsOf: UInt32(sampleRate))
        data.append(contentsOf: byteRate)
        data.append(contentsOf: blockAlign)
        data.append(contentsOf: bitsPerSample)
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: subchunk2Size)
        data.append(pcm)

        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

private extension Data {
    mutating func append<T>(contentsOf value: T) {
        var copy = value
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }
}
