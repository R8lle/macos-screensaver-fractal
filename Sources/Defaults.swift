import Foundation
import ScreenSaver

/// Palette, formula, and zoom speed.
///
/// A UserDefaults suite (not ScreenSaverDefaults.synchronize) so the test
/// host and System Settings can share values without blocking cfprefsd.
enum Defaults {
    static let moduleName = "de.r8lle.screensaver.fractal"

    private static let store: UserDefaults = UserDefaults(suiteName: moduleName)
        ?? .standard

    private static func setValue(_ value: Any?, forKey key: String) {
        store.set(value, forKey: key)
    }

    private static func string(forKey key: String) -> String? {
        store.string(forKey: key)
    }

    private static func object(forKey key: String) -> Any? {
        store.object(forKey: key)
    }

    private static func integer(forKey key: String) -> Int {
        store.integer(forKey: key)
    }

    // MARK: - Palette

    static let paletteKey = "palette"
    static let defaultPalette = "r8lle"
    static let paletteChoices: [(id: String, displayName: String)] = [
        ("r8lle", "R8lle"),
        ("classic", "Klassisch"),
        ("fire", "Feuer"),
        ("ice", "Eis"),
        ("gold", "Gold"),
        ("violet", "Violett"),
        ("mono", "Mono"),
    ]
    private static let validPalettes = Set(paletteChoices.map(\.id))

    static func paletteIndex(for id: String) -> UInt32 {
        switch id {
        case "classic": return 1
        case "fire": return 2
        case "ice": return 3
        case "gold": return 4
        case "violet": return 5
        case "mono": return 6
        default: return 0
        }
    }

    static func readPalette() -> String {
        if let value = string(forKey: paletteKey), validPalettes.contains(value) {
            return value
        }
        return defaultPalette
    }

    static func writePalette(_ palette: String) {
        let resolved = validPalettes.contains(palette) ? palette : defaultPalette
        setValue(resolved, forKey: paletteKey)
    }

    // MARK: - Formula

    static let formulaKey = "formula"
    static let defaultFormula = "mandelbrot"

    static func readFormula() -> String {
        if let value = string(forKey: formulaKey),
           FormulaCatalog.all.contains(where: { $0.id == value }) {
            return value
        }
        return defaultFormula
    }

    static func writeFormula(_ formula: String) {
        let resolved = FormulaCatalog.all.contains(where: { $0.id == formula })
            ? formula
            : defaultFormula
        setValue(resolved, forKey: formulaKey)
    }

    // MARK: - Zoom speed (percent)

    static let speedKey = "zoom_speed_percent"
    static let defaultSpeed = 100
    static let minSpeed = 50
    static let maxSpeed = 200

    static func readSpeedPercent() -> Int {
        let value = object(forKey: speedKey) == nil
            ? defaultSpeed
            : integer(forKey: speedKey)
        return min(maxSpeed, max(minSpeed, value))
    }

    static func writeSpeedPercent(_ percent: Int) {
        setValue(min(maxSpeed, max(minSpeed, percent)), forKey: speedKey)
    }
}
