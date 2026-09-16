import Cocoa

private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}

/// Options window: formula + palette + zoom speed + HUD toggle.
final class ConfigureSheetController: NSObject, NSWindowDelegate {
    let window: NSWindow
    weak var owner: FractalSaverView?

    private let formulaPopup: NSPopUpButton
    private let palettePopup: NSPopUpButton
    private let speedSlider: NSSlider
    private let speedValue: NSTextField
    private let hudCheckbox: NSButton
    private var didEnd = false

    init(owner: FractalSaverView?) {
        self.owner = owner
        let width: CGFloat = 420
        let height: CGFloat = 290

        let content = FlippedContentView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Fractal — Einstellungen"
        window.contentView = content
        self.window = window

        func label(_ text: String, _ frame: NSRect) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.frame = frame
            return field
        }

        content.addSubview(label("Fraktal:", NSRect(x: 20, y: 20, width: 140, height: 22)))
        let formulaPopup = NSPopUpButton(frame: NSRect(x: 170, y: 16, width: 230, height: 26), pullsDown: false)
        for choice in FormulaCatalog.choices {
            formulaPopup.addItem(withTitle: choice.displayName)
        }
        self.formulaPopup = formulaPopup
        content.addSubview(formulaPopup)

        content.addSubview(label("Farbpalette:", NSRect(x: 20, y: 58, width: 140, height: 22)))
        let palettePopup = NSPopUpButton(frame: NSRect(x: 170, y: 54, width: 230, height: 26), pullsDown: false)
        for choice in Defaults.paletteChoices {
            palettePopup.addItem(withTitle: choice.displayName)
        }
        self.palettePopup = palettePopup
        content.addSubview(palettePopup)

        content.addSubview(label("Zoom-Geschwindigkeit:", NSRect(x: 20, y: 96, width: 140, height: 22)))
        let speedSlider = NSSlider(frame: NSRect(x: 170, y: 96, width: 170, height: 24))
        speedSlider.minValue = Double(Defaults.minSpeed)
        speedSlider.maxValue = Double(Defaults.maxSpeed)
        speedSlider.numberOfTickMarks = 7
        speedSlider.allowsTickMarkValuesOnly = false
        self.speedSlider = speedSlider
        content.addSubview(speedSlider)

        let speedValue = NSTextField(labelWithString: "")
        speedValue.frame = NSRect(x: 348, y: 96, width: 52, height: 22)
        speedValue.alignment = .right
        self.speedValue = speedValue
        content.addSubview(speedValue)

        let hudCheckbox = NSButton(
            checkboxWithTitle: "FPS / Pfad anzeigen",
            target: nil,
            action: nil
        )
        hudCheckbox.frame = NSRect(x: 20, y: 134, width: 380, height: 24)
        self.hudCheckbox = hudCheckbox
        content.addSubview(hudCheckbox)

        let bundle = Bundle(for: FractalSaverView.self)
        let shortVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildVersion = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let buildLabel = label("Build: \(buildVersion) (\(shortVersion))", NSRect(x: 20, y: 172, width: 380, height: 18))
        buildLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        buildLabel.textColor = .secondaryLabelColor
        content.addSubview(buildLabel)

        let year = Calendar.current.component(.year, from: Date())
        let copyrightLabel = label("© \(year) R@lle", NSRect(x: 20, y: 194, width: 380, height: 18))
        copyrightLabel.font = .systemFont(ofSize: 11)
        copyrightLabel.textColor = .secondaryLabelColor
        content.addSubview(copyrightLabel)

        let cancel = NSButton(frame: NSRect(x: 210, y: 230, width: 90, height: 32))
        cancel.title = "Abbrechen"
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)

        let ok = NSButton(frame: NSRect(x: 310, y: 230, width: 90, height: 32))
        ok.title = "OK"
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        content.addSubview(ok)

        super.init()

        window.delegate = self
        speedSlider.target = self
        speedSlider.action = #selector(speedChanged(_:))
        cancel.target = self
        cancel.action = #selector(cancelClicked(_:))
        ok.target = self
        ok.action = #selector(okClicked(_:))

        loadFromDefaults()
    }

    private func loadFromDefaults() {
        let formula = Defaults.readFormula()
        if let idx = FormulaCatalog.choices.firstIndex(where: { $0.id == formula }) {
            formulaPopup.selectItem(at: idx)
        }
        let palette = Defaults.readPalette()
        if let idx = Defaults.paletteChoices.firstIndex(where: { $0.id == palette }) {
            palettePopup.selectItem(at: idx)
        }
        let speed = Defaults.readSpeedPercent()
        speedSlider.integerValue = speed
        speedValue.stringValue = "\(speed)%"
        hudCheckbox.state = Defaults.readShowHud() ? .on : .off
    }

    @objc private func speedChanged(_ sender: NSSlider) {
        speedValue.stringValue = "\(sender.integerValue)%"
    }

    @objc private func okClicked(_ sender: NSButton) {
        let fidx = formulaPopup.indexOfSelectedItem
        let pidx = palettePopup.indexOfSelectedItem
        let formula = FormulaCatalog.choices.indices.contains(fidx)
            ? FormulaCatalog.choices[fidx].id
            : Defaults.defaultFormula
        let palette = Defaults.paletteChoices.indices.contains(pidx)
            ? Defaults.paletteChoices[pidx].id
            : Defaults.defaultPalette
        owner?.commitConfiguration(
            formula: formula,
            palette: palette,
            speed: speedSlider.integerValue,
            showHud: hudCheckbox.state == .on
        )
        endSheet()
    }

    @objc private func cancelClicked(_ sender: NSButton) {
        endSheet()
    }

    private func endSheet() {
        guard !didEnd else { return }
        didEnd = true
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        owner?.configureSheetDidClose()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didEnd else { return }
        didEnd = true
        owner?.configureSheetDidClose()
    }
}
