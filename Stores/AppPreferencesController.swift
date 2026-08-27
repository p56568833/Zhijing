import Observation
import SwiftUI

enum AppColorScheme: String, CaseIterable {
    case system
    case light
    case dark

    var name: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
@Observable
final class AppPreferencesController {
    var favorites: Set<String> {
        didSet { defaults.set(Array(favorites), forKey: Keys.favorites) }
    }
    var isSidebarVisible: Bool {
        didSet { defaults.set(isSidebarVisible, forKey: Keys.sidebarVisible) }
    }
    var isAnnotationRailVisible: Bool {
        didSet {
            defaults.set(isAnnotationRailVisible, forKey: Keys.annotationRailVisible)
        }
    }
    var colorScheme: AppColorScheme {
        didSet { defaults.set(colorScheme.rawValue, forKey: Keys.colorScheme) }
    }
    var excludedFoldersText: String {
        didSet { defaults.set(excludedFoldersText, forKey: Keys.excludedFolders) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        isSidebarVisible = defaults.object(
            forKey: Keys.sidebarVisible
        ) as? Bool ?? true
        isAnnotationRailVisible = defaults.object(
            forKey: Keys.annotationRailVisible
        ) as? Bool ?? true
        colorScheme = AppColorScheme(
            rawValue: defaults.string(forKey: Keys.colorScheme) ?? ""
        ) ?? .system
        excludedFoldersText = defaults.string(
            forKey: Keys.excludedFolders
        ) ?? ".git, node_modules"
    }

    private enum Keys {
        static let favorites = "favorites"
        static let excludedFolders = "excludedFolders"
        static let sidebarVisible = "sidebarVisible"
        static let annotationRailVisible = "annotationRailVisible"
        static let colorScheme = "colorScheme"
    }
}
