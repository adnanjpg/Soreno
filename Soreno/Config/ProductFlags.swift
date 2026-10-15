import Foundation

enum ProductFlags {
    private enum InfoDictionaryKey {
        static let localBuild = "SorenoLocalBuild"
    }

    static let isDebugBuild: Bool = {
#if DEBUG
        true
#else
        false
#endif
    }()

    static let isLocalBuild: Bool = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: InfoDictionaryKey.localBuild) else {
            return false
        }

        if let boolValue = value as? Bool {
            return boolValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }

        if let stringValue = value as? String {
            return NSString(string: stringValue).boolValue
        }

        return false
    }()

    static let behavesLikeDebugBuild = isDebugBuild || isLocalBuild

    static let showsLanguageUI = false
    static let supportsMultiLanguage = false
    static let showsSmartPostProcessingControls = false
    static let forcesSmartPostProcessingOn = false
    static let showsAdvancedPostProcessingEditors = false
    static let supportsOfflineReadAloudVoice = false

    static var smartPostProcessingEnabled: Bool {
        false
    }
}
