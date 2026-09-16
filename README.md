# Fractal

macOS screensaver: a quiet endless zoom into fractals (Swift/Metal).
Universal Binary, macOS 13+.

Current release: **1.0 (7)** — notarized (Developer ID).

*[Deutsche Version weiter unten](#fractal-deutsch)*

## Download

Pre-built, notarized release (macOS 13+):

**[FractalSaver.dmg](https://github.com/R8lle/macos-screensaver-fractal/releases/latest)** — double-click the `.saver` inside, choose
"Install for me" or "Install for all users", then select **Fractal** in
**System Settings → Screen Saver**.

## Build

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Xcode.

```bash
./tools/build.sh
```

That generates `FractalSaver.xcodeproj`, builds `FractalSaver.saver`, and copies
it to `~/Library/Screen Savers/`. Then reopen **System Settings → Screen Saver**
and pick **Fractal**.

To try it in a normal window (no System Settings):

```bash
./tools/run_test.sh
```

Options: formula, colour palette and zoom speed (also **Fractal Test → Optionen…** / Cmd+, in the test window).

Release / notarized DMG:

```bash
./tools/release.sh
```

## Identity

- Bundle: `de.r8lle.screensaver.fractal`
- Product: `FractalSaver.saver`
- Copyright: © R@lle
- License: MIT

Signing uses placeholder `YOUR_TEAM_ID` in source. Real Developer ID values
belong in gitignored `tools/local-signing.env`.

---

# Fractal (Deutsch)

macOS-Bildschirmschoner: ruhiger Endlos-Zoom in Fraktale (Swift/Metal).
Aktuelle Version: **1.0 (7)** — notarisiert.

**[FractalSaver.dmg](https://github.com/R8lle/macos-screensaver-fractal/releases/latest)** herunterladen, `.saver` doppelklicken, dann in den
**Systemeinstellungen → Bildschirmschoner** **Fractal** wählen.

```bash
./tools/build.sh
```

installiert `FractalSaver.saver` nach `~/Library/Screen Savers/`.

Zum Ausprobieren in einem normalen Fenster (ohne Systemeinstellungen):

```bash
./tools/run_test.sh
```

Optionen: Fraktal, Farbpalette und Zoom-Geschwindigkeit.
