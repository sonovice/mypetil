import AppKit
import Carbon.HIToolbox

/// ⌃⌥ + a letter or digit opens an app, folder or file — the job skhd used to do.
struct Launcher: Codable, Equatable {
    /// One lowercase letter or digit.
    var key: String
    /// An app bundle, folder or file; `~` is expanded.
    var path: String
    /// Start another instance of the app (`open -n`), e.g. for a new terminal window.
    var newInstance = false

    init(key: String, path: String, newInstance: Bool = false) {
        self.key = key
        self.path = path
        self.newInstance = newInstance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        path = try c.decode(String.self, forKey: .path)
        newInstance = try c.decodeIfPresent(Bool.self, forKey: .newInstance) ?? false
    }

    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    var isApp: Bool { url.pathExtension == "app" }
    var displayName: String { FileManager.default.displayName(atPath: url.path) }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    var keyCode: Int? { Self.keyCodes[key.lowercased()] }

    func open() {
        guard isApp else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = newInstance
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { NSLog("mypetil: could not open \(path): \(error)") }
        }
    }

    /// Keys that mypetil itself uses with ⌃⌥.
    static let reservedKeys: Set<String> = ["g", "m"]

    /// Virtual key codes of the ANSI letters and digits.
    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]
}
