import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let outputContainer = "settings.outputContainer"
        static let preset = "settings.preset"
        static let destination = "settings.destination"
        static let customFolderBookmark = "settings.customFolderBookmark"
        static let customFolderName = "settings.customFolderName"
        static let hardwareAcceleration = "settings.hardwareAcceleration"
        static let preserveMetadata = "settings.preserveMetadata"
        static let preserveHDR = "settings.preserveHDR"
        static let concurrentJobs = "settings.concurrentJobs"
        static let keepHistory = "settings.keepHistory"
        static let confirmReplace = "settings.confirmReplace"
        static let keepImports = "settings.keepImports"
        static let diagnosticsEnabled = "settings.diagnosticsEnabled"
        static let appearance = "settings.appearance"
    }

    private let defaults = UserDefaults.standard

    var defaultOutputContainer: OutputContainer {
        didSet { defaults.set(defaultOutputContainer.rawValue, forKey: Keys.outputContainer) }
    }

    var defaultPreset: ConversionPreset {
        didSet { defaults.set(defaultPreset.rawValue, forKey: Keys.preset) }
    }

    var defaultDestination: OutputDestination {
        didSet { defaults.set(defaultDestination.rawValue, forKey: Keys.destination) }
    }

    var customFolderBookmark: Data? {
        didSet { defaults.set(customFolderBookmark, forKey: Keys.customFolderBookmark) }
    }

    var customFolderName: String? {
        didSet { defaults.set(customFolderName, forKey: Keys.customFolderName) }
    }

    var hardwareAcceleration: Bool {
        didSet { defaults.set(hardwareAcceleration, forKey: Keys.hardwareAcceleration) }
    }

    var preserveMetadata: Bool {
        didSet { defaults.set(preserveMetadata, forKey: Keys.preserveMetadata) }
    }

    var preserveHDR: Bool {
        didSet { defaults.set(preserveHDR, forKey: Keys.preserveHDR) }
    }

    var concurrentJobs: Int {
        didSet { defaults.set(concurrentJobs, forKey: Keys.concurrentJobs) }
    }

    var keepHistory: Bool {
        didSet { defaults.set(keepHistory, forKey: Keys.keepHistory) }
    }

    var keepImports: Bool {
        didSet { defaults.set(keepImports, forKey: Keys.keepImports) }
    }

    var diagnosticsEnabled: Bool {
        didSet { defaults.set(diagnosticsEnabled, forKey: Keys.diagnosticsEnabled) }
    }

    var appearance: AppearanceOption {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    init() {
        defaultOutputContainer = OutputContainer(rawValue: defaults.string(forKey: Keys.outputContainer) ?? "") ?? .mp4
        defaultPreset = ConversionPreset(rawValue: defaults.string(forKey: Keys.preset) ?? "") ?? .balanced
        defaultDestination = OutputDestination(rawValue: defaults.string(forKey: Keys.destination) ?? "") ?? .filesDocuments
        customFolderBookmark = defaults.data(forKey: Keys.customFolderBookmark)
        customFolderName = defaults.string(forKey: Keys.customFolderName)
        hardwareAcceleration = defaults.object(forKey: Keys.hardwareAcceleration) as? Bool ?? true
        preserveMetadata = defaults.object(forKey: Keys.preserveMetadata) as? Bool ?? true
        preserveHDR = defaults.object(forKey: Keys.preserveHDR) as? Bool ?? true
        concurrentJobs = defaults.object(forKey: Keys.concurrentJobs) as? Int ?? 1
        keepHistory = defaults.object(forKey: Keys.keepHistory) as? Bool ?? true
        keepImports = defaults.object(forKey: Keys.keepImports) as? Bool ?? true
        diagnosticsEnabled = defaults.object(forKey: Keys.diagnosticsEnabled) as? Bool ?? false
        appearance = AppearanceOption(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
    }

    func apply(to config: inout ConversionConfiguration) {
        config.outputContainer = defaultOutputContainer
        config.hardwareAcceleration = hardwareAcceleration
        config.preserveMetadata = preserveMetadata
        config.preserveHDR = preserveHDR
    }
}

enum AppearanceOption: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return L10n.appearanceSystem
        case .light: return L10n.appearanceLight
        case .dark: return L10n.appearanceDark
        }
    }
}