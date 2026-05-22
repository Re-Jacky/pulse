import AppKit
import Combine

enum AppTheme: String, CaseIterable {
    case system = "system"
    case dark   = "dark"
    case light  = "light"

    var label: String {
        switch self {
        case .system: return "System"
        case .dark:   return "Dark"
        case .light:  return "Light"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark:   return NSAppearance(named: .darkAqua)
        case .light:  return NSAppearance(named: .aqua)
        }
    }
}

final class ThemeManager: ObservableObject {
    static let userDefaultsKey = "appTheme"

    @Published var currentTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: Self.userDefaultsKey)
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.userDefaultsKey) ?? ""
        currentTheme = AppTheme(rawValue: saved) ?? .dark
    }
}
