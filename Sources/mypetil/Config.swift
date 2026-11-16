import Foundation
import MypetilCore

/// User settings, read from `~/.config/mypetil/config.json`. Every key is optional.
struct Config: Codable {
    /// Space between tiles.
    var gap: CGFloat = 8
    /// Space between tiles and the screen edges / sidebar.
    var outerGap: CGFloat = 8
    var sidebarWidth: CGFloat = 220
    var tabBarHeight: CGFloat = 28
    /// Share of a tile (per dimension) that counts as "middle" when dropping → tab.
    var centerZoneFraction: CGFloat = 0.4
    /// Bundle identifiers whose windows never get tiled.
    var floatingApps: [String] = [
        "com.apple.systempreferences",
        "com.apple.SystemPreferences",
        "com.apple.calculator",
        "com.apple.ActivityMonitor",
        "com.apple.archiveutility",
    ]

    var layoutOptions: LayoutOptions {
        LayoutOptions(gap: gap, tabBarHeight: tabBarHeight)
    }

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mypetil/config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            NSLog("mypetil: ignoring invalid config at \(fileURL.path): \(error)")
            return Config()
        }
    }

    /// Writes the defaults so users have something to edit.
    static func writeDefaultIfMissing() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Config()) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }
}

extension Config {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        gap = try c.decodeIfPresent(CGFloat.self, forKey: .gap) ?? d.gap
        outerGap = try c.decodeIfPresent(CGFloat.self, forKey: .outerGap) ?? d.outerGap
        sidebarWidth = try c.decodeIfPresent(CGFloat.self, forKey: .sidebarWidth) ?? d.sidebarWidth
        tabBarHeight = try c.decodeIfPresent(CGFloat.self, forKey: .tabBarHeight) ?? d.tabBarHeight
        centerZoneFraction = try c.decodeIfPresent(CGFloat.self, forKey: .centerZoneFraction) ?? d.centerZoneFraction
        floatingApps = try c.decodeIfPresent([String].self, forKey: .floatingApps) ?? d.floatingApps
    }

    private static let defaults = Config()
}
