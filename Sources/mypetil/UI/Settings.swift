import AppKit
import ServiceManagement
import SwiftUI

/// The classic macOS preferences window. Every change applies immediately.
@MainActor
final class SettingsWindowController {
    private let store: ConfigStore
    private var window: NSWindow?

    init(store: ConfigStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(store: store))
            let window = NSWindow(contentViewController: controller)
            window.title = "mypetil Einstellungen"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Bindable var store: ConfigStore

    var body: some View {
        TabView {
            GeneralSettings(store: store)
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            LayoutSettings(store: store)
                .tabItem { Label("Layout", systemImage: "rectangle.split.3x1") }
            FloatingSettings(store: store)
                .tabItem { Label("Schwebend", systemImage: "macwindow.on.rectangle") }
            ControlsHelp()
                .tabItem { Label("Bedienung", systemImage: "computermouse") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tabs

private struct GeneralSettings: View {
    @Bindable var store: ConfigStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Fokus") {
                Toggle("Rahmen um aktives Fenster", isOn: $store.config.showFocusBorder)
                PointSlider(title: "Rahmenstärke", value: $store.config.focusBorderWidth, range: 1...6, step: 0.5)
                    .disabled(!store.config.showFocusBorder)
            }
            Section("Seitenleiste") {
                PointSlider(title: "Breite", value: $store.config.sidebarWidth,
                            range: Config.sidebarWidthRange, step: 10)
                Text("Die Breite lässt sich auch direkt an der rechten Kante der Seitenleiste ziehen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

private struct LayoutSettings: View {
    @Bindable var store: ConfigStore

    var body: some View {
        Form {
            Section("Abstände") {
                PointSlider(title: "Zwischen Fenstern", value: $store.config.gap, range: 0...24, step: 1)
                PointSlider(title: "Zum Bildschirmrand", value: $store.config.outerGap, range: 0...24, step: 1)
            }
            Section("Tabs") {
                PointSlider(title: "Höhe der Tab-Leiste", value: $store.config.tabBarHeight, range: 20...40, step: 1)
                LabeledContent("Tab-Zone beim Ablegen") {
                    HStack {
                        Slider(value: $store.config.centerZoneFraction, in: 0.2...0.8, step: 0.05)
                        Text("\(Int(store.config.centerZoneFraction * 100)) %")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Text("Anteil der Fenstermitte, in dem ein abgelegtes Fenster zum Tab wird.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FloatingSettings: View {
    @Bindable var store: ConfigStore

    var body: some View {
        Form {
            Section {
                if store.config.floatingApps.isEmpty {
                    Text("Keine Apps").foregroundStyle(.secondary)
                }
                ForEach(store.config.floatingApps, id: \.self) { bundleID in
                    HStack {
                        AppLabel(bundleID: bundleID)
                        Spacer()
                        Button {
                            store.config.floatingApps.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Entfernen")
                    }
                }
            } header: {
                Text("Apps, deren Fenster nie gekachelt werden")
            } footer: {
                Menu("App hinzufügen …") {
                    ForEach(addableApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            if let id = app.bundleIdentifier { store.config.floatingApps.append(id) }
                        }
                    }
                }
                .fixedSize()
            }
        }
        .formStyle(.grouped)
    }

    private var addableApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && !store.config.floatingApps.contains($0.bundleIdentifier!) && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

private struct ControlsHelp: View {
    var body: some View {
        Form {
            Section("Maus") {
                LabeledContent("⌥ + Linksklick ziehen", value: "Fenster verschieben")
                LabeledContent("… auf Fensterhälfte ablegen", value: "Platz teilen")
                LabeledContent("… in Fenstermitte ablegen", value: "Als Tab hinzufügen")
                LabeledContent("⌥ + Rechtsklick ziehen", value: "Größe ändern")
                LabeledContent("Tab anklicken / herausziehen", value: "Wechseln / lösen")
                LabeledContent("Fensterrand ziehen", value: "Nachbarn passen sich an")
                LabeledContent("Doppelklick Titelleiste", value: "Maximieren")
                LabeledContent("Esc während des Ziehens", value: "Abbrechen")
            }
            Section("Tastatur") {
                LabeledContent("⌃⌥F", value: "Fenster schweben lassen / kacheln")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Controls

private struct PointSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value)) pt" : String(format: "%.1f pt", value))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

private struct AppLabel: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
                if url != nil {
                    Text(bundleID).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
