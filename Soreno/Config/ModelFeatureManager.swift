import Foundation
import Combine

enum SorenoFeatureKey: String, CaseIterable, Identifiable {
    case englishSTT = "english_stt"
    case smartPostProcessing = "smart_post_processing"
    case multiLanguageSTT = "multi_language_stt"
    case enhancedTTS = "enhanced_tts"
    case appleTTS = "apple_tts"

    var id: String { rawValue }
}

enum SorenoModelKey: String, CaseIterable, Hashable, Identifiable {
    case parakeetEnglish = "parakeet_tdt_0_6b_v2"
    case llamaPostProcessing = "llama_3_2_1b_4bit"
    case whisperMultilingual = "whisper_small_mlx"
    case piperEnhancedTTS = "piper"

    var id: String { rawValue }
}

struct SorenoFeatureDescriptor {
    let key: SorenoFeatureKey
    let title: String
    let detail: String
    let isRequired: Bool
    let defaultEnabled: Bool
    let modelKey: SorenoModelKey?
}

struct SorenoModelDescriptor {
    let key: SorenoModelKey
    let title: String
    let directoryName: String
    let isRequired: Bool
    let downloadSizeLabel: String
    let approximateDownloadBytes: Int64?
}

enum ModelProvisionPhase: Equatable {
    case idle
    case installing(progress: Double, detail: String)
    case failed(message: String)
}

struct ModelProvisionState: Equatable {
    let isInstalled: Bool
    let installedBytes: Int64
    let phase: ModelProvisionPhase
}

enum ModelFeatureManagerError: LocalizedError {
    case unknownModel(SorenoModelKey)
    case cannotDeleteRequiredModel(String)
    case modelSourceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unknownModel:
            return "Unknown feature model."
        case .cannotDeleteRequiredModel(let modelName):
            return "\(modelName) are required and cannot be deleted"
        case .modelSourceUnavailable(let modelName):
            return "No local or remote source is configured for \(modelName)"
        }
    }
}

@MainActor
final class ModelFeatureManager: ObservableObject {
    @Published private(set) var modelStates: [SorenoModelKey: ModelProvisionState] = [:]

    let featureDescriptors = FeatureModelCatalog.featureDescriptors
    let modelDescriptors = FeatureModelCatalog.publicModelDescriptors

    private let config: AppConfig
    private let fileManager: FileManager
    private var cancellables = Set<AnyCancellable>()
    private var installTasks: [SorenoModelKey: Task<Void, Never>] = [:]

    init(config: AppConfig, fileManager: FileManager = .default) {
        self.config = config
        self.fileManager = fileManager

        refreshModelStates()
        observeFeatureToggles()

        Task {
            await ensureEnabledFeatureModelsInstalled()
        }
    }

    func state(for model: SorenoModelKey) -> ModelProvisionState {
        modelStates[model] ?? ModelProvisionState(isInstalled: false, installedBytes: 0, phase: .idle)
    }

    func isFeatureEnabled(_ feature: SorenoFeatureKey) -> Bool {
        switch feature {
        case .englishSTT:
            return true
        case .smartPostProcessing:
            return ProductFlags.smartPostProcessingEnabled
        case .multiLanguageSTT:
            return ProductFlags.supportsMultiLanguage && config.isMultiLanguageSTTEnabled
        case .enhancedTTS:
            return ProductFlags.supportsOfflineReadAloudVoice && config.isEnhancedTTSEnabled
        case .appleTTS:
            return config.isAppleTTSEnabled
        }
    }

    func installedModelPath(for model: SorenoModelKey) -> URL? {
        guard let descriptor = FeatureModelCatalog.model(by: model),
              let path = try? destinationURL(for: descriptor),
              fileManager.fileExists(atPath: path.path)
        else {
            return nil
        }
        return path
    }

    func refreshModelStates() {
        var nextState: [SorenoModelKey: ModelProvisionState] = [:]

        for descriptor in FeatureModelCatalog.internalModelDescriptors {
            let installedPath = try? destinationURL(for: descriptor)
            let isInstalled = installedPath.map { fileManager.fileExists(atPath: $0.path) } ?? false
            let installedBytes = (isInstalled && installedPath != nil)
                ? (try? directoryByteSize(at: installedPath!)) ?? 0
                : 0

            let previousPhase = modelStates[descriptor.key]?.phase ?? .idle
            let phase: ModelProvisionPhase
            switch previousPhase {
            case .installing:
                phase = previousPhase
            case .failed where !isInstalled:
                phase = previousPhase
            default:
                phase = .idle
            }

            nextState[descriptor.key] = ModelProvisionState(
                isInstalled: isInstalled,
                installedBytes: installedBytes,
                phase: phase
            )
        }

        modelStates = nextState
    }

    func installModelIfNeeded(_ model: SorenoModelKey) async {
        guard let descriptor = FeatureModelCatalog.model(by: model) else {
            setFailedState(for: model, message: ModelFeatureManagerError.unknownModel(model).localizedDescription)
            return
        }

        if installedModelPath(for: model) != nil {
            refreshModelStates()
            return
        }

        if let existingTask = installTasks[model] {
            await existingTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.installModel(descriptor)
                self.refreshModelStates()
            } catch {
                self.setFailedState(for: model, message: error.localizedDescription)
                self.refreshModelStates()
            }

            self.installTasks[model] = nil
        }

        installTasks[model] = task
        await task.value
    }

    func deleteModelIfPresent(_ model: SorenoModelKey) throws {
        guard let descriptor = FeatureModelCatalog.model(by: model) else {
            throw ModelFeatureManagerError.unknownModel(model)
        }

        guard !descriptor.isRequired else {
            throw ModelFeatureManagerError.cannotDeleteRequiredModel(descriptor.title)
        }

        let destination = try destinationURL(for: descriptor)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        refreshModelStates()
    }

    private func observeFeatureToggles() {
        config.$isSmartPostProcessingEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self, enabled else { return }
                Task { await self.installModelIfNeeded(.llamaPostProcessing) }
            }
            .store(in: &cancellables)

        config.$isMultiLanguageSTTEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self, enabled else { return }
                Task { await self.installModelIfNeeded(.whisperMultilingual) }
            }
            .store(in: &cancellables)

        config.$isEnhancedTTSEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self, enabled else { return }
                Task { await self.installModelIfNeeded(.piperEnhancedTTS) }
            }
            .store(in: &cancellables)
    }

    private func ensureEnabledFeatureModelsInstalled() async {
        if isFeatureEnabled(.smartPostProcessing) {
            await installModelIfNeeded(.llamaPostProcessing)
        }

        if isFeatureEnabled(.multiLanguageSTT) {
            await installModelIfNeeded(.whisperMultilingual)
        }

        if isFeatureEnabled(.enhancedTTS) {
            await installModelIfNeeded(.piperEnhancedTTS)
        }
    }

    private func installModel(_ descriptor: FeatureModelCatalog.InternalModelDescriptor) async throws {
        let destination = try destinationURL(for: descriptor)
        if fileManager.fileExists(atPath: destination.path) {
            return
        }

        setInstallingState(for: descriptor.key, progress: 0, detail: "Preparing download")

        do {
            if let seedDirectory = descriptor.seedDirectoryName,
               let source = LocalModelBootstrap.sourceModelPathIfPresent(directoryName: seedDirectory, fileManager: fileManager) {
                try installByCopying(from: source, to: destination, model: descriptor.key)
                return
            }

            if let remote = descriptor.remoteManifest {
                try await installByDownloading(remote, to: destination, model: descriptor.key)
                return
            }

            throw ModelFeatureManagerError.modelSourceUnavailable(descriptor.title)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }
    }

    private func installByCopying(from source: URL, to destination: URL, model: SorenoModelKey) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let files = try regularFiles(in: source)
        let totalBytes = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)
        var copiedBytes: Int64 = 0

        for file in files {
            let relativePath = file.url.path.replacingOccurrences(of: source.path + "/", with: "")
            let target = destination.appendingPathComponent(relativePath, isDirectory: false)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }

            try fileManager.copyItem(at: file.url, to: target)
            copiedBytes += file.size

            let progress = min(1, Double(copiedBytes) / Double(totalBytes))
            setInstallingState(for: model, progress: progress, detail: "Copying model")
        }
    }

    private func installByDownloading(
        _ manifest: FeatureModelCatalog.RemoteFileManifest,
        to destination: URL,
        model: SorenoModelKey
    ) async throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let totalFiles = max(manifest.files.count, 1)
        for (index, relativePath) in manifest.files.enumerated() {
            let remoteURL = manifest.baseURL.appendingPathComponent(relativePath)
            let destinationFile = destination.appendingPathComponent(relativePath)

            try fileManager.createDirectory(
                at: destinationFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            setInstallingState(
                for: model,
                progress: Double(index) / Double(totalFiles),
                detail: "Downloading model"
            )

            let (temporaryFile, _) = try await URLSession.shared.download(from: remoteURL)
            if fileManager.fileExists(atPath: destinationFile.path) {
                try fileManager.removeItem(at: destinationFile)
            }
            try fileManager.moveItem(at: temporaryFile, to: destinationFile)

            setInstallingState(
                for: model,
                progress: Double(index + 1) / Double(totalFiles),
                detail: "Installing model"
            )
        }
    }

    private func setInstallingState(for model: SorenoModelKey, progress: Double, detail: String) {
        let current = modelStates[model] ?? ModelProvisionState(isInstalled: false, installedBytes: 0, phase: .idle)
        modelStates[model] = ModelProvisionState(
            isInstalled: current.isInstalled,
            installedBytes: current.installedBytes,
            phase: .installing(progress: progress, detail: detail)
        )
    }

    private func setFailedState(for model: SorenoModelKey, message: String) {
        let current = modelStates[model] ?? ModelProvisionState(isInstalled: false, installedBytes: 0, phase: .idle)
        modelStates[model] = ModelProvisionState(
            isInstalled: current.isInstalled,
            installedBytes: current.installedBytes,
            phase: .failed(message: message)
        )
    }

    private func destinationURL(for descriptor: FeatureModelCatalog.InternalModelDescriptor) throws -> URL {
        let root: URL
        switch descriptor.storage {
        case .fluidAudioModels:
            root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
        case .sorenoModels:
            root = try LocalModelBootstrap.modelsRootURL()
        }

        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        return root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
    }

    private func directoryByteSize(at path: URL) throws -> Int64 {
        let files = try regularFiles(in: path)
        return files.reduce(Int64(0)) { $0 + $1.size }
    }

    private func regularFiles(in root: URL) throws -> [(url: URL, size: Int64)] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, size: Int64)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            files.append((url, Int64(values.fileSize ?? 0)))
        }

        return files
    }
}

private enum FeatureModelCatalog {
    enum ModelStorageLocation {
        case fluidAudioModels
        case sorenoModels
    }

    struct RemoteFileManifest {
        let baseURL: URL
        let files: [String]
    }

    struct InternalModelDescriptor {
        let key: SorenoModelKey
        let title: String
        let directoryName: String
        let isRequired: Bool
        let downloadSizeLabel: String
        let approximateDownloadBytes: Int64?
        let storage: ModelStorageLocation
        let seedDirectoryName: String?
        let remoteManifest: RemoteFileManifest?
    }

    static let featureDescriptors: [SorenoFeatureDescriptor] = [
        SorenoFeatureDescriptor(
            key: .englishSTT,
            title: "English speech-to-text",
            detail: "Required for English transcription",
            isRequired: true,
            defaultEnabled: true,
            modelKey: .parakeetEnglish
        ),
        SorenoFeatureDescriptor(
            key: .smartPostProcessing,
            title: "Smart post-processing",
            detail: "Optional cleanup after transcription",
            isRequired: false,
            defaultEnabled: false,
            modelKey: .llamaPostProcessing
        ),
        SorenoFeatureDescriptor(
            key: .multiLanguageSTT,
            title: "Multi-language speech-to-text",
            detail: "Optional support for non-English transcription",
            isRequired: false,
            defaultEnabled: false,
            modelKey: .whisperMultilingual
        ),
        SorenoFeatureDescriptor(
            key: .enhancedTTS,
            title: "Offline read-aloud voice",
            detail: "Optional local read-aloud runtime",
            isRequired: false,
            defaultEnabled: false,
            modelKey: .piperEnhancedTTS
        ),
        SorenoFeatureDescriptor(
            key: .appleTTS,
            title: "Read-aloud voices",
            detail: "Uses the built-in Soreno voice library",
            isRequired: false,
            defaultEnabled: true,
            modelKey: nil
        ),
    ]

    static let internalModelDescriptors: [InternalModelDescriptor] = [
        InternalModelDescriptor(
            key: .parakeetEnglish,
            title: "English speech-to-text model",
            directoryName: "parakeet-tdt-0.6b-v2",
            isRequired: true,
            downloadSizeLabel: "Bundled/required",
            approximateDownloadBytes: nil,
            storage: .fluidAudioModels,
            seedDirectoryName: nil,
            remoteManifest: RemoteFileManifest(
                baseURL: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/resolve/main")!,
                files: [
                    "Preprocessor.mlmodelc/coremldata.bin",
                    "Preprocessor.mlmodelc/metadata.json",
                    "Preprocessor.mlmodelc/model.mil",
                    "Preprocessor.mlmodelc/analytics/coremldata.bin",
                    "Preprocessor.mlmodelc/weights/weight.bin",
                    "Encoder.mlmodelc/coremldata.bin",
                    "Encoder.mlmodelc/metadata.json",
                    "Encoder.mlmodelc/model.mil",
                    "Encoder.mlmodelc/analytics/coremldata.bin",
                    "Encoder.mlmodelc/weights/weight.bin",
                    "Decoder.mlmodelc/coremldata.bin",
                    "Decoder.mlmodelc/metadata.json",
                    "Decoder.mlmodelc/model.mil",
                    "Decoder.mlmodelc/analytics/coremldata.bin",
                    "Decoder.mlmodelc/weights/weight.bin",
                    "JointDecision.mlmodelc/coremldata.bin",
                    "JointDecision.mlmodelc/metadata.json",
                    "JointDecision.mlmodelc/model.mil",
                    "JointDecision.mlmodelc/analytics/coremldata.bin",
                    "JointDecision.mlmodelc/weights/weight.bin",
                    "parakeet_vocab.json",
                ]
            )
        ),
        InternalModelDescriptor(
            key: .llamaPostProcessing,
            title: "Smart post-processing model",
            directoryName: LocalModelBootstrap.llamaDirectoryName,
            isRequired: false,
            downloadSizeLabel: "~0.7 GB",
            approximateDownloadBytes: 700_000_000,
            storage: .sorenoModels,
            seedDirectoryName: LocalModelBootstrap.llamaDirectoryName,
            remoteManifest: RemoteFileManifest(
                baseURL: URL(string: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit/resolve/main")!,
                files: [
                    "config.json",
                    "model.safetensors",
                    "model.safetensors.index.json",
                    "special_tokens_map.json",
                    "tokenizer_config.json",
                    "tokenizer.json",
                ]
            )
        ),
        InternalModelDescriptor(
            key: .whisperMultilingual,
            title: "Multi-language speech-to-text model",
            directoryName: LocalModelBootstrap.whisperDirectoryName,
            isRequired: false,
            downloadSizeLabel: "~0.2-0.5 GB",
            approximateDownloadBytes: 250_000_000,
            storage: .sorenoModels,
            seedDirectoryName: LocalModelBootstrap.whisperDirectoryName,
            remoteManifest: RemoteFileManifest(
                baseURL: URL(string: "https://huggingface.co/mlx-community/whisper-small-mlx/resolve/main")!,
                files: [
                    "config.json",
                    "weights.npz",
                ]
            )
        ),
        InternalModelDescriptor(
            key: .piperEnhancedTTS,
            title: "Offline read-aloud model",
            directoryName: LocalModelBootstrap.piperDirectoryName,
            isRequired: false,
            downloadSizeLabel: "~65 MB",
            approximateDownloadBytes: 65_000_000,
            storage: .sorenoModels,
            seedDirectoryName: LocalModelBootstrap.piperDirectoryName,
            remoteManifest: RemoteFileManifest(
                baseURL: URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main")!,
                files: [
                    "en/en_US/lessac/medium/en_US-lessac-medium.onnx",
                    "en/en_US/lessac/medium/en_US-lessac-medium.onnx.json",
                ]
            )
        ),
    ]

    static let publicModelDescriptors: [SorenoModelDescriptor] = internalModelDescriptors.compactMap {
        guard isUserVisibleModel($0.key) else {
            return nil
        }

        return SorenoModelDescriptor(
            key: $0.key,
            title: publicTitle(for: $0.key),
            directoryName: $0.directoryName,
            isRequired: $0.isRequired,
            downloadSizeLabel: $0.downloadSizeLabel,
            approximateDownloadBytes: $0.approximateDownloadBytes
        )
    }

    private static let modelLookup: [SorenoModelKey: InternalModelDescriptor] = {
        Dictionary(uniqueKeysWithValues: internalModelDescriptors.map { ($0.key, $0) })
    }()

    static func model(by key: SorenoModelKey) -> InternalModelDescriptor? {
        modelLookup[key]
    }

    private static func isUserVisibleModel(_ key: SorenoModelKey) -> Bool {
        switch key {
        case .parakeetEnglish:
            return false
        case .llamaPostProcessing:
            return ProductFlags.showsSmartPostProcessingControls
        case .whisperMultilingual:
            return ProductFlags.showsLanguageUI
        case .piperEnhancedTTS:
            return ProductFlags.supportsOfflineReadAloudVoice
        }
    }

    private static func publicTitle(for key: SorenoModelKey) -> String {
        switch key {
        case .parakeetEnglish:
            return "English speech-to-text"
        case .llamaPostProcessing:
            return "Smart post-processing"
        case .whisperMultilingual:
            return "Multi-language speech-to-text"
        case .piperEnhancedTTS:
            return "Offline read-aloud voice"
        }
    }
}
