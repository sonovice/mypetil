import AppKit
import ServiceManagement
import SwiftUI

/// The classic macOS preferences window: icon tabs in the toolbar, right-aligned labels.
/// Every change applies immediately.
@MainActor
final class SettingsWindowController {
    private let store: ConfigStore
    private var window: NSWindow?

    init(store: ConfigStore) {
        self.store = store
    }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        tabs.addTabViewItem(pane("Allgemein", "gearshape", GeneralPane(store: store)))
        tabs.addTabViewItem(pane("Layout", "rectangle.split.3x1", LayoutPane(store: store)))
        tabs.addTabViewItem(pane("Schwebend", "macwindow.on.rectangle", FloatingPane(store: store)))
        tabs.addTabViewItem(pane("Tastatur", "keyboard", KeyboardPane(store: store)))
        tabs.addTabViewItem(pane("Maus", "computermouse", MousePane()))

        tabs.canPropagateSelectedChildViewControllerTitle = true
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func pane<Content: View>(_ title: String, _ symbol: String, _ content: Content) -> NSTabViewItem {
        let host = NSHostingController(rootView: content.padding(.horizontal, 30).padding(.vertical, 22).frame(width: 520))
        // The window follows each pane's size when switching tabs.
        host.sizingOptions = [.preferredContentSize]
        let item = NSTabViewItem(viewController: host)
        item.label = title
        host.title = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @Bindable var store: ConfigStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsGrid {
            SettingsRow("Autostart:") {
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError { Hint(loginError) }
            }
            SettingsDivider()
            SettingsRow("Fokus:") {
                Toggle("Rahmen um das aktive Fenster", isOn: $store.config.showFocusBorder)
            }
            SettingsRow("Rahmenstärke:") {
                ValueSlider(value: $store.config.focusBorderWidth, range: 1...6, step: 0.5, unit: "pt")
                    .disabled(!store.config.showFocusBorder)
            }
            SettingsRow("Eckenradius:") {
                ValueSlider(value: $store.config.windowCornerRadius, range: 0...30, step: 1, unit: "pt")
                    .disabled(!store.config.showFocusBorder)
                Hint("An die Rundung der Fensterecken anpassen, damit der Rahmen genau anliegt.")
            }
            SettingsDivider()
            SettingsRow("Seitenleiste:") {
                ValueSlider(value: $store.config.sidebarWidth, range: Config.sidebarWidthRange, step: 10, unit: "pt")
                Hint("Lässt sich auch an der rechten Kante der Seitenleiste ziehen.")
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Nur möglich, wenn mypetil als App (build/mypetil.app) läuft."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct LayoutPane: View {
    @Bindable var store: ConfigStore

    var body: some View {
        SettingsGrid {
            SettingsRow("Zwischen Fenstern:") {
                ValueSlider(value: $store.config.gap, range: 0...24, step: 1, unit: "pt")
            }
            SettingsRow("Seitenabstand:") {
                ValueSlider(value: $store.config.outerGap, range: 0...24, step: 1, unit: "pt")
                Hint("Links und rechts. Oben und unten reichen die Fenster bis an den Rand.")
            }
            SettingsDivider()
            SettingsRow("Tab-Leiste:") {
                ValueSlider(value: $store.config.tabBarHeight, range: 24...52, step: 1, unit: "pt")
            }
            SettingsRow("Tab-Zone:") {
                ValueSlider(value: $store.config.centerZoneFraction, range: 0.2...0.8, step: 0.05, unit: "%", scale: 100)
                Hint("Anteil der Fenstermitte, in dem ein abgelegtes Fenster zum Tab wird.")
            }
        }
    }
}

private struct FloatingPane: View {
    @Bindable var store: ConfigStore
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fenster dieser Apps werden nie gekachelt:")
            VStack(spacing: 0) {
                List(store.config.floatingApps, id: \.self, selection: $selection) { bundleID in
                    AppLabel(bundleID: bundleID)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 200)
                ListFooter(removeHelp: "Ausgewählte App entfernen", canRemove: selection != nil, remove: {
                    if let selection { store.config.floatingApps.removeAll { $0 == selection } }
                    selection = nil
                }) {
                    Menu {
                        ForEach(addableApps, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                                if let id = app.bundleIdentifier { store.config.floatingApps.append(id) }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.borderlessButton)
                    .frame(width: 24, height: 20)
                    .help("App hinzufügen")
                }
            }
            .overlay(Rectangle().stroke(Color(nsColor: .separatorColor)))
            Hint("Einzelne Fenster schweben lassen: ⌃⌥G oder Rechtsklick in der Seitenleiste.")
        }
    }

    private var addableApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
                return !store.config.floatingApps.contains(id) && app.processIdentifier != getpid()
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

private struct KeyboardPane: View {
    @Bindable var store: ConfigStore
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGrid {
                SettingsRow("⌃⌥G:") { Text("Fenster schweben lassen / kacheln") }
                SettingsRow("⌃⌥M:") { Text("Fenster maximieren / zurück") }
            }
            Divider().padding(.vertical, 6)
            Text("⌃⌥ + Taste öffnet eine App, einen Ordner oder eine Datei:")
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.config.launchers.indices, id: \.self) { i in
                        LauncherRow(launcher: $store.config.launchers[i], isDuplicate: isDuplicate(i))
                            .tag(i)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 220)
                ListFooter(addHelp: "App oder Ordner hinzufügen", removeHelp: "Ausgewähltes Kürzel entfernen",
                           canRemove: selection != nil, add: add, remove: remove)
            }
            .overlay(Rectangle().stroke(Color(nsColor: .separatorColor)))
            Hint("Bei „Neues Fenster“ wird die App erneut gestartet, z. B. für ein weiteres Terminal.")
        }
    }

    private func isDuplicate(_ i: Int) -> Bool {
        let key = store.config.launchers[i].key
        guard !key.isEmpty else { return false }
        return Launcher.reservedKeys.contains(key)
            || store.config.launchers.indices.contains { $0 != i && store.config.launchers[$0].key == key }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Hinzufügen"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        store.config.launchers.append(Launcher(key: suggestedKey(for: url), path: path))
        selection = store.config.launchers.count - 1
    }

    /// The first letter of the name that is still free.
    private func suggestedKey(for url: URL) -> String {
        let taken = Set(store.config.launchers.map(\.key)).union(Launcher.reservedKeys)
        let name = FileManager.default.displayName(atPath: url.path).lowercased()
        return name.map(String.init).first { Launcher.keyCodes[$0] != nil && !taken.contains($0) } ?? ""
    }

    private func remove() {
        if let selection, store.config.launchers.indices.contains(selection) {
            store.config.launchers.remove(at: selection)
        }
        selection = nil
    }
}

private struct LauncherRow: View {
    @Binding var launcher: Launcher
    let isDuplicate: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Text("⌃⌥").foregroundStyle(.secondary)
                TextField("", text: keyBinding)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 28)
            }
            .help(isDuplicate ? "Diese Taste ist schon belegt." : "Taste (Buchstabe oder Ziffer)")
            if isDuplicate {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            Image(nsImage: launcher.icon).resizable().frame(width: 18, height: 18)
            Text(launcher.displayName).lineLimit(1)
            Spacer()
            if launcher.isApp {
                Toggle("Neues Fenster", isOn: $launcher.newInstance)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
        }
        .help(launcher.path)
    }

    /// Keeps exactly one letter or digit, lowercased.
    private var keyBinding: Binding<String> {
        Binding(
            get: { launcher.key.uppercased() },
            set: { text in
                let last = text.lowercased().map(String.init).last { Launcher.keyCodes[$0] != nil }
                launcher.key = last ?? ""
            }
        )
    }
}

private struct MousePane: View {
    var body: some View {
        SettingsGrid {
            SettingsRow("⌥ + Linksklick ziehen:") { Text("Fenster verschieben") }
            SettingsRow("… auf Fensterhälfte:") { Text("Platz teilen") }
            SettingsRow("… in Fenstermitte:") { Text("Als Tab hinzufügen") }
            SettingsRow("⌥ + Rechtsklick ziehen:") { Text("Größe ändern (Ecke oder Kante)") }
            SettingsRow("Esc während des Ziehens:") { Text("Abbrechen") }
            SettingsDivider()
            SettingsRow("Fensterrand ziehen:") { Text("Nachbarfenster passen sich an") }
            SettingsRow("Doppelklick Titelleiste:") { Text("Maximieren") }
            SettingsRow("Tab anklicken / ziehen:") { Text("Wechseln / herauslösen") }
        }
    }
}

// MARK: - Building blocks

/// The +/− bar under an editable list.
private struct ListFooter<AddButton: View>: View {
    let removeHelp: String
    let canRemove: Bool
    let remove: () -> Void
    @ViewBuilder let addButton: AddButton

    init(removeHelp: String, canRemove: Bool, remove: @escaping () -> Void,
         @ViewBuilder addButton: () -> AddButton) {
        self.removeHelp = removeHelp
        self.canRemove = canRemove
        self.remove = remove
        self.addButton = addButton()
    }

    var body: some View {
        HStack(spacing: 0) {
            addButton
            Divider().frame(height: 16)
            Button(action: remove) {
                Image(systemName: "minus").frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .help(removeHelp)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

extension ListFooter where AddButton == AnyView {
    /// A plain + button.
    init(addHelp: String, removeHelp: String, canRemove: Bool, add: @escaping () -> Void,
         remove: @escaping () -> Void) {
        self.init(removeHelp: removeHelp, canRemove: canRemove, remove: remove) {
            AnyView(Button(action: add) {
                Image(systemName: "plus").frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .help(addHelp))
        }
    }
}

/// Two columns: right-aligned labels, left-aligned controls.
private struct SettingsGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
            content
        }
        .toggleStyle(.checkbox)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 4) {
                content
            }
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .gridCellUnsizedAxes(.horizontal)
            .padding(.vertical, 4)
    }
}

private struct ValueSlider: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
    let unit: String
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .frame(width: 200)
            Text(formatted)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
        }
    }

    private var formatted: String {
        let v = value * scale
        return (v.rounded() == v ? "\(Int(v))" : String(format: "%.1f", v)) + " " + unit
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 300, alignment: .leading)
    }
}

private struct AppLabel: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            Group {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    Image(systemName: "questionmark.app").resizable()
                }
            }
            .frame(width: 18, height: 18)
            Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
            Spacer()
            Text(bundleID).font(.caption).foregroundStyle(.tertiary)
        }
    }
}
