import Foundation
import MypetilCore
import Observation

/// User settings, stored in `~/.config/mypetil/config.json`. Every key is optional.
struct Config: Codable, Equatable {
    /// Bumped when defaults change in a way that should reach existing config files.
    var configVersion = Config.currentVersion
    /// Space between tiles.
    var gap: CGFloat = 6
    /// Space between tiles and the screen edges / sidebar.
    var outerGap: CGFloat = 4
    var sidebarWidth: CGFloat = 220
    var tabBarHeight: CGFloat = 28
    /// Coloured frame around the focused window.
    var showFocusBorder = true
    var focusBorderWidth: CGFloat = 2.5
    /// Share of a tile (per dimension) that counts as "middle" when dropping → tab.
    var centerZoneFraction: CGFloat = 0.4
    /// Bundle identifiers whose windows never get tiled.
    var floatingApps: [String] = [
        "com.apple.systempreferences",
        "com.apple.calculator",
        "com.apple.ActivityMonitor",
        "com.apple.archiveutility",
    ]

    static let currentVersion = 2
    static let sidebarWidthRange: ClosedRange<CGFloat> = 150...420

    var layoutOptions: LayoutOptions {
        LayoutOptions(gap: gap, tabBarHeight: tabBarHeight)
    }

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mypetil/config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data).migrated()
        } catch {
            NSLog("mypetil: ignoring invalid config at \(fileURL.path): \(error)")
            return Config()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("mypetil: could not save config: \(error)")
        }
    }

    /// Version 1 wrote all defaults into the file, so untouched old defaults are replaced.
    private func migrated() -> Config {
        var c = self
        if c.configVersion < 2 {
            if c.gap == 8 { c.gap = Config().gap }
            if c.outerGap == 8 { c.outerGap = Config().outerGap }
        }
        c.configVersion = Self.currentVersion
        return c
    }
}

extension Config {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        configVersion = try c.decodeIfPresent(Int.self, forKey: .configVersion) ?? 1
        gap = try c.decodeIfPresent(CGFloat.self, forKey: .gap) ?? d.gap
        outerGap = try c.decodeIfPresent(CGFloat.self, forKey: .outerGap) ?? d.outerGap
        sidebarWidth = try c.decodeIfPresent(CGFloat.self, forKey: .sidebarWidth) ?? d.sidebarWidth
        tabBarHeight = try c.decodeIfPresent(CGFloat.self, forKey: .tabBarHeight) ?? d.tabBarHeight
        showFocusBorder = try c.decodeIfPresent(Bool.self, forKey: .showFocusBorder) ?? d.showFocusBorder
        focusBorderWidth = try c.decodeIfPresent(CGFloat.self, forKey: .focusBorderWidth) ?? d.focusBorderWidth
        centerZoneFraction = try c.decodeIfPresent(CGFloat.self, forKey: .centerZoneFraction) ?? d.centerZoneFraction
        floatingApps = try c.decodeIfPresent([String].self, forKey: .floatingApps) ?? d.floatingApps
    }
}

/// The single source of truth for settings: edited by the settings window and the
/// sidebar's resize handle, persisted to disk, and pushed to the window manager.
@Observable
@MainActor
final class ConfigStore {
    var config: Config {
        didSet {
            guard config != oldValue else { return }
            scheduleSave()
            onChange?(config)
        }
    }

    @ObservationIgnored var onChange: ((Config) -> Void)?
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    init() {
        config = Config.load()
        config.save()   // persists migrations and gives users a file to edit
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.config.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
