import AppKit
import Foundation

/// The window's appearance, as a user preference rather than a system setting.
///
/// The palette already had a light and a dark set; the only thing missing was a way to choose one
/// without changing the whole desktop. "Follow the system" stays the default, so the app keeps doing
/// what it did before unless someone asks otherwise.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// The appearance to force, or nil to inherit. `NSAppearance` is AppKit's own vocabulary, which
    /// is what `NSApplication.appearance` and `NSHostingView` both take.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Remembers the choice between launches.
///
/// A tiny JSON file beside the other local state, rather than `UserDefaults`: the app already keeps
/// its queue, credentials and tokens in that directory, and one more preference is not worth a second
/// storage mechanism.
struct AppearanceStore {
    private let url: URL

    init(supportDirectory: URL) {
        url = supportDirectory.appendingPathComponent("appearance.json")
    }

    func load() -> AppearanceMode {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(String.self, from: data),
              let mode = AppearanceMode(rawValue: raw)
        else { return .system }
        return mode
    }

    func save(_ mode: AppearanceMode) {
        guard let data = try? JSONEncoder().encode(mode.rawValue) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
