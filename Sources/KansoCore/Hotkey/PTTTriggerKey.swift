import Foundation

/// Push-To-Talk trigger selection for the global Option hotkey.
/// Persisted in UserDefaults under `ptt_trigger_key`. Defaults to Right Option only.
public enum PTTTriggerKey: String, Sendable, CaseIterable, Equatable {
    case rightOption
    case leftOption
    case eitherOption

    public static let defaultsKey = "ptt_trigger_key"

    public static var `default`: PTTTriggerKey { .rightOption }

    public var displayName: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .leftOption: return "Left Option (⌥)"
        case .eitherOption: return "Either Option (⌥)"
        }
    }

    public var shortHint: String {
        switch self {
        case .rightOption: return "Hold Right Option"
        case .leftOption: return "Hold Left Option"
        case .eitherOption: return "Hold Either Option"
        }
    }

    public static func load(defaults: UserDefaults = .standard) -> PTTTriggerKey {
        guard let raw = defaults.string(forKey: defaultsKey) else { return .default }
        return PTTTriggerKey(rawValue: raw) ?? .default
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: PTTTriggerKey.defaultsKey)
    }
}
