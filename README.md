# mypetil

Ein Tiling-Window-Manager für macOS mit Fensterleiste am linken Bildschirmrand, Maus-Drag-and-Drop und Tabs.

## Funktionen

- **Automatisches Tiling (BSP):** Ein neues Fenster halbiert das fokussierte Fenster, und zwar entlang der längeren Seite.
- **⌥ + Linksklick-Ziehen** verschiebt ein Fenster. Ein Overlay zeigt die Zielposition, eine Live-Vorschau des Fensters gibt es nicht.
  - Loslassen auf der linken, rechten, oberen oder unteren Hälfte eines Fensters halbiert dessen Platz.
  - Loslassen in der Mitte fügt das Fenster als **Tab** hinzu.
  - Funktioniert auch über Bildschirmgrenzen hinweg und mit schwebenden Fenstern (die dabei gekachelt werden).
  - <kbd>Esc</kbd> bricht den Vorgang ab.
- **⌥ + Rechtsklick-Ziehen** ändert die Größe. Das Fenster ist dafür in ein 3×3-Raster eingeteilt: Eckfelder bewegen die Ecke, Kantenfelder die Kante, das Mittelfeld die nächste Ecke. Dabei werden die Split-Grenzen live mitgezogen.
- **Tabs:** Ein Tab lässt sich in der Tab-Leiste anklicken oder herausziehen (dafür braucht es kein ⌥). Tabs werden nie verschachtelt. Ein herausgezogenes Tab wird wieder zu einem normalen Fenster, und eine Gruppe mit nur noch einem Fenster verliert ihre Tab-Leiste.
- **Mindestgrößen werden respektiert:** Wenn ein Fenster nicht kleiner werden will, merkt sich mypetil diese Größe und vergibt den Platz neu. Passt die Summe aller Mindestgrößen nicht auf den Bildschirm, wird der Platz proportional verteilt.
- **Seitenleiste** am linken Rand jedes Bildschirms. Sie zeigt alle Fenster mit Icon, Titel und App und stellt Tab-Gruppen eingerückt dar. Ein Klick fokussiert das Fenster, ein Rechtsklick öffnet ein Menü (Schweben, Minimieren, Schließen).
- Das Ziehen an der Fensterkante (ganz normal, ohne ⌥) verschiebt ebenfalls die Split-Grenzen. Ein Fenster, das man an der Titelleiste verschoben hat, springt zurück auf seinen Platz.

## Tastenkürzel

| Kürzel | Aktion |
|---|---|
| ⌃⌥ H / J / K / L | Fokus links / unten / oben / rechts |
| ⌃⌥⇧ H / J / K / L | Mit dem Nachbarn tauschen |
| ⌃⌥ Tab / ⌃⌥⇧ Tab | Nächster / vorheriger Tab |
| ⌃⌥ E | Split-Richtung umschalten |
| ⌃⌥ F | Fenster schweben lassen / kacheln |
| ⌃⌥ B | Alle Splits auf 50/50 |
| ⌃⌥ R | Neu anordnen |

Als Modifier dient ⌃⌥ statt nur ⌥, denn ⌥+Buchstabe erzeugt auf deutscher Tastatur Sonderzeichen (⌥L = @).

## Bauen und starten

```sh
./scripts/bundle.sh          # erzeugt build/mypetil.app
open build/mypetil.app
```

Beim ersten Start fragt macOS nach der **Bedienungshilfen**-Berechtigung (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen). Sobald sie erteilt ist, startet mypetil von selbst. Die App ist ad-hoc signiert, deshalb muss die Berechtigung nach einem Neubau eventuell neu gesetzt werden.

Zum Entwickeln geht auch `xcrun swift run`. Die Berechtigung gilt dann für das Terminal. Tests laufen mit `xcrun swift test`.

> Hinweis: Mit `xcrun` wird die Xcode-Toolchain verwendet. Eine per swiftly installierte Toolchain passt nicht zum macOS-SDK von Xcode.

## Konfiguration

`~/.config/mypetil/config.json` wird beim ersten Start angelegt. Alle Schlüssel sind optional:

```json
{
  "gap": 8,
  "outerGap": 8,
  "sidebarWidth": 220,
  "tabBarHeight": 28,
  "centerZoneFraction": 0.4,
  "floatingApps": ["com.apple.systempreferences", "com.apple.calculator"]
}
```

## Architektur

```
Sources/MypetilCore/      reine Layout-Logik, ohne AppKit, vollständig getestet
  LayoutTree.swift          Binärbaum: Splits (Achse + Ratio) und Tab-Gruppen als Blätter
  Geometry.swift            Drop-Zonen, Resize-Kanten
Sources/mypetil/
  WindowManager.swift       Zustand und Orchestrierung: AX-Events → Baum → Fensterrahmen
  MouseController.swift     CGEvent-Tap: ⌥-Drag, ⌥-Resize, Tab-Klicks
  AX/                       Accessibility-Wrapper und AXObserver je App
  UI/                       Seitenleiste (SwiftUI), Tab-Leisten, Drop-Overlay
  Hotkeys.swift             Carbon-Hotkeys
```

Der Baum speichert nur die **Absicht**, also Split-Achsen, Ratios und die Reihenfolge der Tabs. Die konkreten Rechtecke berechnet `layout(in:minSizes:)` bei jedem Durchlauf neu. Dabei setzen sich die Mindestgrößen gegenüber den Ratios durch. Schließt man das Fenster, das die Mindestgröße erzwungen hat, gilt wieder das gewünschte Verhältnis.

### Ideen aus anderen Projekten

| Idee | Vorbild |
|---|---|
| BSP-Tiling, neues Fenster halbiert das fokussierte; Fenster-IDs über `_AXUIElementGetWindow` | [yabai](https://github.com/koekeishiya/yabai) |
| Kein SIP-Deaktivieren und keine privaten Spaces-APIs; inaktive Tabs werden in die Bildschirmecke geparkt statt minimiert | [AeroSpace](https://github.com/nikitabobko/AeroSpace) |
| Drag & Drop mit Zonen: Rand teilt, Mitte erzeugt einen Tab | [FancyWM](https://github.com/FancyWM/fancywm), [Pop Shell](https://github.com/pop-os/shell) |
| `AXEnhancedUserInterface` beim Verschieben aus, gegen träge Animationen | yabai / Amethyst |
| ⌥ + Rechtsklick-Resize mit Ecken und Kanten | i3 / bspwm / yabai |

## Bekannte Einschränkungen / nächste Schritte

- **Spaces:** mypetil verwaltet die Fenster, die macOS gerade meldet. Wie bei AeroSpace empfiehlt sich ein Space pro Bildschirm.
- AX-Aufrufe laufen auf dem Main-Thread. Eine hängende App kann mypetil deshalb kurz ausbremsen. Ein Thread pro App wäre der nächste Schritt.
- Die Mindestgrößen werden aus dem Verhalten der Fenster gelernt, denn macOS hat dafür keine öffentliche API. Beim ersten Platzieren kann ein Fenster deshalb kurz zu groß sein.
- Tastenkürzel sind noch nicht konfigurierbar.
