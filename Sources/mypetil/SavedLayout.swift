import CoreGraphics
import Foundation
import MypetilCore

/// The layout trees of all workspaces, saved so a restart of mypetil keeps every window
/// in its place. Window IDs stay valid as long as their app keeps running; windows that
/// are gone by then are simply left out when restoring.
struct SavedLayout: Codable {
    struct SavedWorkspace: Codable {
        let displayID: CGDirectDisplayID
        let spaceID: Spaces.ID
        let tree: LayoutSnapshot
        let zoomed: CGWindowID?
    }

    var workspaces: [SavedWorkspace] = []
    /// Windows the user floated by hand.
    var floating: [CGWindowID] = []

    static let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("mypetil/layout.json")

    static func load() -> SavedLayout? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SavedLayout.self, from: data)
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("mypetil: could not save layout: \(error)")
        }
    }
}
