import Foundation
import Carbon
import AVFoundation

/// App configuration backed by UserDefaults.
final class AppConfig: ObservableObject {
    private enum Keys {
        static let mode = "mode"
        static let hotkeyKind = "hotkey.kind"
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let hotkeyDisplayName = "hotkey.displayName"

        static let isSmartPostProcessingEnabled = "feature.smartPostProcessing"
        static let isMultiLanguageSTTEnabled = "feature.multiLanguageSTT"
        static let isAppleTTSEnabled = "feature.appleTTS"
        static let isEnhancedTTSEnabled = "feature.enhancedTTS"

        static let postProcessingModel = "model.postProcessing"
        static let whisperModel = "model.whisper"
        static let activeLanguage = "language.active"
        static let openDesktopAppOnLaunch = "app.openDesktopOnLaunch"
        static let hasCompletedFirstLaunch = "app.hasCompletedFirstLaunch"
        static let readAloudVoiceIdentifier = "tts.readAloudVoiceIdentifier"
        static let readAloudRate = "tts.readAloudRate"

        static let userProfilePrompt = "profile.userPrompt"
        static let customDictionaryEntries = "profile.customDictionaryEntries"
        static let correctionMemoryEntries = "profile.correctionMemoryEntries"
        static let recentTranscriptParagraphs = "history.recentTranscriptParagraphs"
        static let recentTranscriptHistoryEntries = "history.recentTranscriptHistoryEntries"
        static let hasCompletedFirstLaunchOnboarding = "onboarding.firstLaunch.completed"
    }

    static let defaultUserProfilePrompt = """
    I am a software engineer and product builder.
    Prioritize technical terms, names, and concise phrasing.
    Preserve intent while formatting output cleanly.
    """
    static let enhancedReadAloudVoiceIdentifier = "__soreno_enhanced__"
    static let systemDefaultReadAloudVoiceIdentifier = "__soreno_system_default__"
    static let aaronReadAloudVoiceIdentifier = "com.apple.ttsbundle.siri_aaron_en-US_compact"
    static let readAloudRateRange: ClosedRange<Double> = 0.25...3.0

    // MARK: - Mode
    @Published var mode: RecordingMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode) }
    }

    // MARK: - Hotkey
    @Published var hotkey: Hotkey {
        didSet { hotkey.save() }
    }

    // MARK: - Audio
    @Published var sampleRate: Int = 16000
    @Published var channels: Int = 1

    // MARK: - Model (internal, not user-facing)
    @Published var modelName: String = "parakeet-tdt-0.6b-v2"

    // MARK: - Desktop Settings

    @Published var isSmartPostProcessingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSmartPostProcessingEnabled, forKey: Keys.isSmartPostProcessingEnabled)
        }
    }

    @Published var isMultiLanguageSTTEnabled: Bool {
        didSet { UserDefaults.standard.set(isMultiLanguageSTTEnabled, forKey: Keys.isMultiLanguageSTTEnabled) }
    }

    @Published var isAppleTTSEnabled: Bool {
        didSet { UserDefaults.standard.set(isAppleTTSEnabled, forKey: Keys.isAppleTTSEnabled) }
    }

    @Published var isEnhancedTTSEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnhancedTTSEnabled, forKey: Keys.isEnhancedTTSEnabled) }
    }

    @Published var postProcessingModel: PostProcessingModel {
        didSet { UserDefaults.standard.set(postProcessingModel.rawValue, forKey: Keys.postProcessingModel) }
    }

    @Published var whisperModel: WhisperModel {
        didSet { UserDefaults.standard.set(whisperModel.rawValue, forKey: Keys.whisperModel) }
    }

    @Published var activeLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(activeLanguage.rawValue, forKey: Keys.activeLanguage) }
    }

    @Published var openDesktopAppOnLaunch: Bool {
        didSet { UserDefaults.standard.set(openDesktopAppOnLaunch, forKey: Keys.openDesktopAppOnLaunch) }
    }

    @Published var hasCompletedFirstLaunch: Bool {
        didSet { UserDefaults.standard.set(hasCompletedFirstLaunch, forKey: Keys.hasCompletedFirstLaunch) }
    }

    @Published var readAloudVoiceIdentifier: String {
        didSet { UserDefaults.standard.set(readAloudVoiceIdentifier, forKey: Keys.readAloudVoiceIdentifier) }
    }

    @Published var readAloudRate: Double {
        didSet {
            let clampedRate = Self.clampReadAloudRate(readAloudRate)
            if clampedRate != readAloudRate {
                readAloudRate = clampedRate
                return
            }

            UserDefaults.standard.set(readAloudRate, forKey: Keys.readAloudRate)
        }
    }

    @Published var userProfilePrompt: String {
        didSet { UserDefaults.standard.set(userProfilePrompt, forKey: Keys.userProfilePrompt) }
    }

    @Published var customDictionaryEntries: [CustomDictionaryEntry] {
        didSet { Self.encode(customDictionaryEntries, forKey: Keys.customDictionaryEntries) }
    }

    @Published var correctionMemoryEntries: [CorrectionMemoryEntry] {
        didSet { Self.encode(correctionMemoryEntries, forKey: Keys.correctionMemoryEntries) }
    }

    @Published var recentTranscriptParagraphs: [String] {
        didSet { Self.encode(recentTranscriptParagraphs, forKey: Keys.recentTranscriptParagraphs) }
    }

    @Published var recentTranscriptHistoryEntries: [TranscriptHistoryEntry] {
        didSet { Self.encode(recentTranscriptHistoryEntries, forKey: Keys.recentTranscriptHistoryEntries) }
    }

    // MARK: - First Launch

    @Published var hasCompletedFirstLaunchOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedFirstLaunchOnboarding, forKey: Keys.hasCompletedFirstLaunchOnboarding) }
    }

    var effectiveSpeechLanguage: AppLanguage {
        ProductFlags.supportsMultiLanguage ? activeLanguage : .english
    }

    enum RecordingMode: String, CaseIterable {
        case pushToTalk = "push-to-talk"
        case toggleMute = "toggle-mute"

        var displayName: String {
            switch self {
            case .pushToTalk: return "Push to Talk"
            case .toggleMute: return "Toggle Mute"
            }
        }
    }

    enum AppLanguage: String, CaseIterable, Codable, Identifiable {
        case english
        case arabic
        case turkish
        case spanish
        case french
        case german
        case portuguese
        case italian
        case dutch
        case russian
        case japanese
        case indonesian
        case chinese
        case ukrainian
        case polish
        case swedish
        case catalan
        case romanian
        case thai
        case finnish

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .english: return "English"
            case .arabic: return "Arabic"
            case .turkish: return "Turkish"
            case .spanish: return "Spanish"
            case .french: return "French"
            case .german: return "German"
            case .portuguese: return "Portuguese"
            case .italian: return "Italian"
            case .dutch: return "Dutch"
            case .russian: return "Russian"
            case .japanese: return "Japanese"
            case .indonesian: return "Indonesian"
            case .chinese: return "Chinese"
            case .ukrainian: return "Ukrainian"
            case .polish: return "Polish"
            case .swedish: return "Swedish"
            case .catalan: return "Catalan"
            case .romanian: return "Romanian"
            case .thai: return "Thai"
            case .finnish: return "Finnish"
            }
        }

        var localeCode: String {
            switch self {
            case .english: return "en"
            case .arabic: return "ar"
            case .turkish: return "tr"
            case .spanish: return "es"
            case .french: return "fr"
            case .german: return "de"
            case .portuguese: return "pt"
            case .italian: return "it"
            case .dutch: return "nl"
            case .russian: return "ru"
            case .japanese: return "ja"
            case .indonesian: return "id"
            case .chinese: return "zh"
            case .ukrainian: return "uk"
            case .polish: return "pl"
            case .swedish: return "sv"
            case .catalan: return "ca"
            case .romanian: return "ro"
            case .thai: return "th"
            case .finnish: return "fi"
            }
        }

        var isEnglish: Bool {
            self == .english
        }

        var engineDescription: String {
            switch self {
            case .english:
                return "English speech-to-text"
            default:
                return "Multi-language speech-to-text"
            }
        }
    }

    enum WhisperModel: String, CaseIterable, Codable, Identifiable {
        case small
        case medium

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .small: return "Faster"
            case .medium: return "Higher accuracy"
            }
        }

        var footprint: String {
            switch self {
            case .small: return "~0.2 GB"
            case .medium: return "~0.5 GB"
            }
        }
    }

    enum PostProcessingModel: String, CaseIterable, Codable, Identifiable {
        case llama32_1b
        case llama32_3b

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .llama32_1b: return "Standard"
            case .llama32_3b: return "Higher accuracy"
            }
        }

        var footprint: String {
            switch self {
            case .llama32_1b: return "~0.7 GB"
            case .llama32_3b: return "~1.8 GB"
            }
        }
    }

    struct CustomDictionaryEntry: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var spoken: String
        var correction: String
        var notes: String

        init(id: UUID = UUID(), spoken: String, correction: String, notes: String = "") {
            self.id = id
            self.spoken = spoken
            self.correction = correction
            self.notes = notes
        }
    }

    struct CorrectionMemoryEntry: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var misrecognized: String
        var corrected: String
        var context: String
        var usageCount: Int
        var lastUpdated: Date

        init(
            id: UUID = UUID(),
            misrecognized: String,
            corrected: String,
            context: String = "",
            usageCount: Int = 1,
            lastUpdated: Date = .now
        ) {
            self.id = id
            self.misrecognized = misrecognized
            self.corrected = corrected
            self.context = context
            self.usageCount = usageCount
            self.lastUpdated = lastUpdated
        }
    }

    struct TranscriptHistoryEntry: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var finalText: String
        var originalText: String?
        var postProcessingEnabled: Bool
        var createdAt: Date

        init(
            id: UUID = UUID(),
            finalText: String,
            originalText: String? = nil,
            postProcessingEnabled: Bool,
            createdAt: Date = .now
        ) {
            self.id = id
            self.finalText = finalText
            self.originalText = originalText
            self.postProcessingEnabled = postProcessingEnabled
            self.createdAt = createdAt
        }
    }

    /// Represents a hotkey — either a modifier-only key (Globe, Right ⌘) or a key + modifiers combo.
    struct Hotkey: Equatable {
        enum Kind: String {
            case globe           // Globe/fn key (modifier-only)
            case modifierOnly    // A single modifier key like Right ⌘ (keycode distinguishes left/right)
            case keyCombo        // Regular key + optional modifiers (e.g. F5, ⌥Space)
        }

        let kind: Kind
        let keyCode: UInt16      // CGEvent keycode (0 for globe)
        let modifiers: UInt32    // CGEventFlags rawValue (masked to relevant bits)
        let displayName: String  // Human-readable label

        // MARK: - Presets

        static let globe = Hotkey(kind: .globe, keyCode: 0, modifiers: 0, displayName: "Globe (fn)")
        static let leftOption = Hotkey(
            kind: .modifierOnly,
            keyCode: 58,
            modifiers: UInt32(CGEventFlags.maskAlternate.rawValue),
            displayName: "Left ⌥"
        )
        static let rightCommand = Hotkey(kind: .modifierOnly, keyCode: 54, modifiers: UInt32(CGEventFlags.maskCommand.rawValue), displayName: "Right ⌘")

        // MARK: - Persistence

        func save() {
            let defaults = UserDefaults.standard
            defaults.set(kind.rawValue, forKey: Keys.hotkeyKind)
            defaults.set(Int(keyCode), forKey: Keys.hotkeyKeyCode)
            defaults.set(Int(modifiers), forKey: Keys.hotkeyModifiers)
            defaults.set(displayName, forKey: Keys.hotkeyDisplayName)
        }

        static func load() -> Hotkey {
            let defaults = UserDefaults.standard
            guard let kindStr = defaults.string(forKey: Keys.hotkeyKind),
                  let kind = Kind(rawValue: kindStr) else {
                return .leftOption
            }
            let keyCode = UInt16(defaults.integer(forKey: Keys.hotkeyKeyCode))
            let modifiers = UInt32(defaults.integer(forKey: Keys.hotkeyModifiers))
            let displayName = defaults.string(forKey: Keys.hotkeyDisplayName) ?? Self.leftOption.displayName
            return Hotkey(kind: kind, keyCode: keyCode, modifiers: modifiers, displayName: displayName)
        }

        // MARK: - Create from CGEvent (for hotkey recorder)

        /// Create a Hotkey from a flagsChanged CGEvent (modifier key press).
        static func fromModifierEvent(keyCode: UInt16, flags: CGEventFlags) -> Hotkey {
            let name = modifierDisplayName(keyCode: keyCode, flags: flags)
            // Determine if this is Globe/fn
            if flags.contains(.maskSecondaryFn) && keyCode == 63 {
                return .globe
            }
            return Hotkey(
                kind: .modifierOnly,
                keyCode: keyCode,
                modifiers: sanitizeModifiers(flags),
                displayName: name
            )
        }

        /// Create a Hotkey from a keyDown CGEvent (regular key + modifiers).
        static func fromKeyEvent(keyCode: UInt16, flags: CGEventFlags) -> Hotkey {
            let modStr = modifierSymbols(flags)
            let keyStr = keyDisplayName(keyCode: keyCode)
            let name = modStr.isEmpty ? keyStr : "\(modStr)\(keyStr)"
            return Hotkey(
                kind: .keyCombo,
                keyCode: keyCode,
                modifiers: sanitizeModifiers(flags),
                displayName: name
            )
        }

        // MARK: - Display helpers

        private static func sanitizeModifiers(_ flags: CGEventFlags) -> UInt32 {
            let mask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
            return UInt32(flags.intersection(mask).rawValue)
        }

        private static func modifierSymbols(_ flags: CGEventFlags) -> String {
            var s = ""
            if flags.contains(.maskControl) { s += "⌃" }
            if flags.contains(.maskAlternate) { s += "⌥" }
            if flags.contains(.maskShift) { s += "⇧" }
            if flags.contains(.maskCommand) { s += "⌘" }
            return s
        }

        private static func modifierDisplayName(keyCode: UInt16, flags: CGEventFlags) -> String {
            // Globe/fn
            if keyCode == 63 || flags.contains(.maskSecondaryFn) {
                return "Globe (fn)"
            }
            // Right Command = 54, Left Command = 55
            if keyCode == 54 { return "Right ⌘" }
            if keyCode == 55 { return "Left ⌘" }
            // Right Option = 61, Left Option = 58
            if keyCode == 61 { return "Right ⌥" }
            if keyCode == 58 { return "Left ⌥" }
            // Right Shift = 60, Left Shift = 56
            if keyCode == 60 { return "Right ⇧" }
            if keyCode == 56 { return "Left ⇧" }
            // Right Control = 62, Left Control = 59
            if keyCode == 62 { return "Right ⌃" }
            if keyCode == 59 { return "Left ⌃" }
            // Caps Lock = 57
            if keyCode == 57 { return "Caps Lock" }
            return "Modifier \(keyCode)"
        }

        private static func keyDisplayName(keyCode: UInt16) -> String {
            // Function keys
            switch keyCode {
            case 122: return "F1"
            case 120: return "F2"
            case 99: return "F3"
            case 118: return "F4"
            case 96: return "F5"
            case 97: return "F6"
            case 98: return "F7"
            case 100: return "F8"
            case 101: return "F9"
            case 109: return "F10"
            case 103: return "F11"
            case 111: return "F12"
            case 105: return "F13"
            case 107: return "F14"
            case 113: return "F15"
            // Special keys
            case 49: return "Space"
            case 36: return "Return"
            case 48: return "Tab"
            case 51: return "Delete"
            case 53: return "Escape"
            case 123: return "←"
            case 124: return "→"
            case 125: return "↓"
            case 126: return "↑"
            default: break
            }
            // Try to get the character from the keycode
            let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            if let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
                let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length: Int = 0
                data.withUnsafeBytes { rawBuf in
                    let ptr = rawBuf.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
                    UCKeyTranslate(
                        ptr,
                        keyCode,
                        UInt16(kUCKeyActionDisplay),
                        0, // no modifiers for display
                        UInt32(LMGetKbdType()),
                        UInt32(kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState,
                        chars.count,
                        &length,
                        &chars
                    )
                }
                if length > 0 {
                    return String(utf16CodeUnits: chars, count: length).uppercased()
                }
            }
            return "Key \(keyCode)"
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.mode = RecordingMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .pushToTalk
        self.hotkey = Hotkey.load()
        self.isSmartPostProcessingEnabled = defaults.object(forKey: Keys.isSmartPostProcessingEnabled) as? Bool ?? ProductFlags.smartPostProcessingEnabled
        self.isMultiLanguageSTTEnabled = defaults.object(forKey: Keys.isMultiLanguageSTTEnabled) as? Bool ?? false
        self.isAppleTTSEnabled = defaults.object(forKey: Keys.isAppleTTSEnabled) as? Bool ?? true
        self.isEnhancedTTSEnabled = defaults.object(forKey: Keys.isEnhancedTTSEnabled) as? Bool ?? false
        self.postProcessingModel = PostProcessingModel(rawValue: defaults.string(forKey: Keys.postProcessingModel) ?? "") ?? .llama32_1b
        self.whisperModel = WhisperModel(rawValue: defaults.string(forKey: Keys.whisperModel) ?? "") ?? .small
        self.activeLanguage = AppLanguage(rawValue: defaults.string(forKey: Keys.activeLanguage) ?? "") ?? .english
        self.openDesktopAppOnLaunch = defaults.object(forKey: Keys.openDesktopAppOnLaunch) as? Bool ?? true
        self.hasCompletedFirstLaunch = defaults.object(forKey: Keys.hasCompletedFirstLaunch) as? Bool ?? false
        self.readAloudVoiceIdentifier = Self.normalizedReadAloudVoiceIdentifier(
            defaults.string(forKey: Keys.readAloudVoiceIdentifier)
        )
        self.readAloudRate = Self.clampReadAloudRate(defaults.object(forKey: Keys.readAloudRate) as? Double ?? 1.0)
        self.userProfilePrompt = defaults.string(forKey: Keys.userProfilePrompt) ?? Self.defaultUserProfilePrompt
        self.customDictionaryEntries = Self.decode([CustomDictionaryEntry].self, forKey: Keys.customDictionaryEntries, defaultValue: [])
        self.correctionMemoryEntries = Self.decode([CorrectionMemoryEntry].self, forKey: Keys.correctionMemoryEntries, defaultValue: [])
        let recentTranscriptParagraphs = Self.decode([String].self, forKey: Keys.recentTranscriptParagraphs, defaultValue: [])
        self.recentTranscriptParagraphs = recentTranscriptParagraphs
        self.recentTranscriptHistoryEntries = Self.decode(
            [TranscriptHistoryEntry].self,
            forKey: Keys.recentTranscriptHistoryEntries,
            defaultValue: recentTranscriptParagraphs.map {
                TranscriptHistoryEntry(finalText: $0, postProcessingEnabled: false)
            }
        )
        self.hasCompletedFirstLaunchOnboarding = defaults.object(forKey: Keys.hasCompletedFirstLaunchOnboarding) as? Bool ?? false
        enforceProductSurface()
    }

    private func enforceProductSurface() {
        if ProductFlags.forcesSmartPostProcessingOn && !isSmartPostProcessingEnabled {
            isSmartPostProcessingEnabled = true
        }

        if !ProductFlags.smartPostProcessingEnabled && isSmartPostProcessingEnabled {
            isSmartPostProcessingEnabled = false
        }

        if !isAppleTTSEnabled {
            isAppleTTSEnabled = true
        }

        if ProductFlags.supportsOfflineReadAloudVoice {
            if !isEnhancedTTSEnabled {
                isEnhancedTTSEnabled = true
            }
        } else if isEnhancedTTSEnabled {
            isEnhancedTTSEnabled = false
        }

        if readAloudVoiceIdentifier == Self.enhancedReadAloudVoiceIdentifier ||
            readAloudVoiceIdentifier == Self.systemDefaultReadAloudVoiceIdentifier {
            readAloudVoiceIdentifier = Self.normalizedReadAloudVoiceIdentifier(nil)
        }

        if !ProductFlags.supportsMultiLanguage {
            if isMultiLanguageSTTEnabled {
                isMultiLanguageSTTEnabled = false
            }
            if activeLanguage != .english {
                activeLanguage = .english
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, forKey key: String, defaultValue: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return defaultValue
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            sorenoLog("Failed to decode UserDefaults key \(key): \(error)")
            return defaultValue
        }
    }

    private static func encode<T: Encodable>(_ value: T, forKey key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            sorenoLog("Failed to encode UserDefaults key \(key): \(error)")
        }
    }

    private static func clampReadAloudRate(_ rate: Double) -> Double {
        min(max(rate, readAloudRateRange.lowerBound), readAloudRateRange.upperBound)
    }

    private static func normalizedReadAloudVoiceIdentifier(_ identifier: String?) -> String {
        if let identifier,
            identifier != enhancedReadAloudVoiceIdentifier,
            identifier != systemDefaultReadAloudVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier),
           isSelectableReadAloudVoice(voice) {
            return identifier
        }

        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("en") }

        if let aaronVoice = AVSpeechSynthesisVoice(identifier: aaronReadAloudVoiceIdentifier),
           isSelectableReadAloudVoice(aaronVoice) {
            return aaronReadAloudVoiceIdentifier
        }

        if let alexVoice = AVSpeechSynthesisVoice(identifier: AVSpeechSynthesisVoiceIdentifierAlex) {
            return alexVoice.identifier
        }

        if let qualityVoice = englishVoices.first(where: { voice in
            !voice.voiceTraits.contains(.isNoveltyVoice) &&
            !voice.voiceTraits.contains(.isPersonalVoice) &&
            (voice.quality == .premium || voice.quality == .enhanced)
        }) {
            return qualityVoice.identifier
        }

        if let standardVoice = englishVoices.first(where: { voice in
            !voice.voiceTraits.contains(.isNoveltyVoice) &&
            !voice.voiceTraits.contains(.isPersonalVoice)
        }) {
            return standardVoice.identifier
        }

        return systemDefaultReadAloudVoiceIdentifier
    }

    private static func isSelectableReadAloudVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        !voice.voiceTraits.contains(.isNoveltyVoice) &&
        !voice.voiceTraits.contains(.isPersonalVoice)
    }
}
