# mypetil

Ein Tiling-Window-Manager für macOS mit Fensterleiste am linken Bildschirmrand, Maus-Drag-and-Drop und Tabs.

## Funktionen

- **Automatisches Tiling (BSP):** Ein neues Fenster halbiert das fokussierte Fenster, und zwar entlang der längeren Seite.
- **⌥ + Linksklick-Ziehen** verschiebt ein Fenster. Eine Vorschau des Fensters (Icon und Titel, mit Fokus-Rahmen) klebt an der Maus und springt auf die Zielfläche, sobald man über einem Fenster ist. Alle gekachelten Fenster werden dabei als Vorschau mit Icon und Titel gezeigt, und zwar in der Größe, die sie nach dem Ablegen hätten. Eine Live-Vorschau des Fensterinhalts gibt es bewusst nicht.
  - Loslassen auf der linken, rechten, oberen oder unteren Hälfte eines Fensters halbiert dessen Platz.
  - Loslassen in der Mitte fügt das Fenster als **Tab** hinzu.
  - Funktioniert auch über Bildschirmgrenzen hinweg und mit schwebenden Fenstern (die dabei gekachelt werden).
  - <kbd>Esc</kbd> bricht den Vorgang ab.
- **⌥ + Rechtsklick-Ziehen** ändert die Größe. Das Fenster ist dafür in Drittel eingeteilt: In einem Eckfeld bewegt sich die Ecke, in einem Kantenfeld die Kante und im Mittelfeld die nächste Ecke. Während des Ziehens sieht man nur die Vorschau mit allen betroffenen Fenstern. Umsortiert wird erst beim Loslassen.
- **Fensterrand ziehen** (ganz normal, ohne ⌥) verschiebt die Split-Grenzen und die Nachbarn passen sich an. Ein Fenster, das man an der Titelleiste verschoben hat, springt zurück auf seinen Platz. Zieht man es an der Titelleiste auf einen anderen Monitor, wird es dort gekachelt, und zwar wie beim ⌥-Ziehen dort, wo man es loslässt.
- **Maximieren** per Doppelklick auf die Titelleiste, ⌥-Klick auf den grünen Knopf oder über das Kontextmenü der Seitenleiste: Das Fenster füllt dann die Kachelfläche. **Natives Vollbild** nimmt das Fenster aus dem Layout, und Seitenleiste und Overlays bleiben dort ausgeblendet.
- **Tabs:** Ein Tab lässt sich anklicken, über das × schließen oder herausziehen (dafür braucht es kein ⌥). Tabs werden nie verschachtelt. Ein herausgezogenes Tab wird wieder zu einem normalen Fenster, und eine Gruppe mit nur noch einem Fenster verliert ihre Tab-Leiste.
- **Fokus-Rahmen** um das aktive Fenster, abschaltbar.
- **Mindestgrößen werden respektiert:** Wenn ein Fenster auch nach einem zweiten Versuch nicht kleiner werden will, merkt sich mypetil diese Größe und vergibt den Platz neu. Passt die Summe aller Mindestgrößen nicht auf den Bildschirm, wird der Platz proportional verteilt.
- **Desktops (Spaces):** Jeder Desktop hat auf jedem Bildschirm sein eigenes Layout. Fenster anderer Desktops bleiben in der Seitenleiste sichtbar.
- **Layout bleibt beim Neustart erhalten:** mypetil speichert das Layout (Teilungen, Tabs, schwebende Fenster) in `~/Library/Application Support/mypetil/layout.json` und stellt es beim nächsten Start wieder her, solange die Apps weiterlaufen.
- **Seitenleiste** am linken Rand jedes Bildschirms im Stil einer Finder-Seitenleiste. Sie zeigt alle Fenster mit Icon, Titel und App und stellt Tab-Gruppen eingerückt dar. Die Breite lässt sich an der rechten Kante ziehen. Ein Klick fokussiert das Fenster, ein Rechtsklick öffnet ein Kontextmenü, und das Zahnrad unten öffnet die **Einstellungen**.

## Tastenkürzel

| Kürzel | Aktion |
|---|---|
| ⌃⌥ G | Fokussiertes Fenster schweben lassen / kacheln |

Alles andere wird mit der Maus bedient.

## Bauen und starten

```sh
./scripts/bundle.sh          # erzeugt build/mypetil.app
open build/mypetil.app
```

Beim ersten Start fragt macOS nach der **Bedienungshilfen**-Berechtigung (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen). Sobald sie erteilt ist, startet mypetil von selbst. Das Skript signiert mit deinem „Apple Development“-Zertifikat, damit die Berechtigung auch nach einem Neubau gültig bleibt. Mit `MYPETIL_SIGN_IDENTITY` lässt sich ein anderes Zertifikat wählen. Ohne Zertifikat wird ad-hoc signiert, und dann muss die Berechtigung nach jedem Neubau neu gesetzt werden.

Zum Entwickeln geht auch `xcrun swift run`. Die Berechtigung gilt dann für das Terminal. Tests laufen mit `xcrun swift test`.

> Hinweis: Mit `xcrun` wird die Xcode-Toolchain verwendet. Eine per swiftly installierte Toolchain passt nicht zum macOS-SDK von Xcode.

## Einstellungen

Die Einstellungen öffnest du über das Zahnrad in der Seitenleiste oder über ⌘, im Menüleisten-Symbol. Dort lassen sich Abstände, Fokus-Rahmen, Breite der Seitenleiste, Höhe der Tab-Leiste, Größe der Tab-Zone, schwebende Apps und der Start bei der Anmeldung festlegen. Änderungen wirken sofort.

Gespeichert wird alles in `~/.config/mypetil/config.json`.

## Architektur

```
Sources/MypetilCore/      reine Layout-Logik, ohne AppKit, vollständig getestet
  LayoutTree.swift          Binärbaum: Splits (Achse + Ratio) und Tab-Gruppen als Blätter
  Geometry.swift            Drop-Zonen, Resize-Kanten
Sources/mypetil/
  WindowManager.swift       Zustand und Orchestrierung: AX-Events → Baum → Fensterrahmen
  InputController.swift     CGEvent-Tap: ⌥-Drag, ⌥-Resize, Tab-Klicks, ⌃⌥G
  Spaces.swift              Desktops (lesende SkyLight-Abfragen)
  AX/                       Accessibility-Wrapper und AXObserver je App
  UI/                       Seitenleiste, Tab-Leisten, Overlays, Fokus-Rahmen, Einstellungen
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

- Ob ein Klick in der Seitenleiste auf ein Fenster eines anderen Desktops dorthin wechselt, hängt von der macOS-Einstellung „Beim Wechseln zu einer App einen Space mit offenen Fenstern auswählen“ ab.
- AX-Aufrufe laufen auf dem Main-Thread. Eine hängende App kann mypetil deshalb kurz ausbremsen. Ein Thread pro App wäre der nächste Schritt.
- Die Mindestgrößen werden aus dem Verhalten der Fenster gelernt, denn macOS hat dafür keine öffentliche API. Beim ersten Platzieren kann ein Fenster deshalb kurz zu groß sein.
