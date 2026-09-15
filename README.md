# Fractal

macOS screensaver: a quiet endless zoom into fractals (Swift/Metal).
Universal Binary, macOS 13+.

Current build: **1.0 (1)** — local first drop, not notarized.

*[Deutsche Version weiter unten](#fractal-deutsch)*

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

## Identity

- Bundle: `de.r8lle.screensaver.fractal`
- Product: `FractalSaver.saver`
- Copyright: R8lle

Signing uses placeholder `YOUR_TEAM_ID` in source. Real Developer ID values
belong in gitignored `tools/local-signing.env`.

---

# Fractal (Deutsch)

macOS-Bildschirmschoner: ruhiger Endlos-Zoom in Fraktale (Swift/Metal).

```bash
./tools/build.sh
```

installiert `FractalSaver.saver` nach `~/Library/Screen Savers/`. In den
**Systemeinstellungen → Bildschirmschoner** **Fractal** wählen.

Zum Ausprobieren in einem normalen Fenster (ohne Systemeinstellungen):

```bash
./tools/run_test.sh
```

Optionen: Fraktal, Farbpalette und Zoom-Geschwindigkeit.
