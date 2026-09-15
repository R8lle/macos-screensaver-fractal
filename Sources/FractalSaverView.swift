import Cocoa
import Metal
import MetalKit
import ScreenSaver

/// Bundle entry (`NSPrincipalClass`). Thin ScreenSaverView + MTKView shell.
@objc(FractalSaverView)
final class FractalSaverView: ScreenSaverView {
    private var mtkView: MTKView!
    private var renderer: Renderer?
    private var sheetController: ConfigureSheetController?
    private var gpuUpgradeInFlight = false
    private var configOpen = false
    private var frameNo = 0
    private var watchdogInternal = false
    private var fpsLabel: NSTextField?
    private var hudFrames = 0
    private var hudWindowStart: CFTimeInterval = 0
    private var lastHudFormula = ""
    private var lastHudPath = ""

    private static let thumbnailPlaceholderSize = NSSize(width: 160, height: 100)

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit(isPreview: isPreview)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit(isPreview: false)
    }

    private func commonInit(isPreview: Bool) {
        animationTimeInterval = isPreview ? 1.0 / 20.0 : 1.0 / 30.0
        // Layer-backed parent so a HUD sibling composites above CAMetalLayer.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        var mtkFrame = bounds
        if mtkFrame.width < 10 || mtkFrame.height < 10 {
            mtkFrame = NSRect(
                origin: .zero,
                size: isPreview ? Self.thumbnailPlaceholderSize : NSSize(width: 800, height: 500)
            )
        }

        let view = MTKView(frame: mtkFrame)
        view.autoresizingMask = [.width, .height]
        view.device = MetalDevicePicker.preferredReady(timeoutSeconds: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        // Sync Metal presents with Core Animation so HUD siblings stay visible.
        view.presentsWithTransaction = true
        view.layer?.magnificationFilter = .linear
        view.layer?.minificationFilter = .linear

        addSubview(view)
        self.mtkView = view
        applyPresentationDrawable()

        if let renderer = Renderer(mtkView: view, isPreview: isPreview) {
            self.renderer = renderer
            view.delegate = renderer
        } else {
            NSLog("[FractalSaver] Renderer initialization failed")
        }

        installFpsHud()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            if watchdogInternal {
                watchdogInternal = false
                mtkView?.isPaused = true
            }
            return
        }
        ensureDiscreteMetalDeviceIfNeeded()
        ensureMtkLayout()
        applyHudVisibility()
    }

    override func startAnimation() {
        super.startAnimation()
        frameNo = 0
        watchdogInternal = false
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(watchdogCheckTicks), object: nil
        )
        perform(#selector(watchdogCheckTicks), with: nil, afterDelay: 2.0)
        ensureDiscreteMetalDeviceIfNeeded()
        ensureMtkLayout()
        renderer?.reloadPreferences()
        renderer?.beginRandomPath()
        applyHudVisibility()
    }

    override func stopAnimation() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(watchdogCheckTicks), object: nil
        )
        if watchdogInternal {
            watchdogInternal = false
            mtkView?.isPaused = true
        }
        super.stopAnimation()
    }

    override func animateOneFrame() {
        guard !configOpen else { return }
        frameNo += 1
        if watchdogInternal { return }
        mtkView.draw()
        tickHud()
    }

    @objc private func watchdogCheckTicks() {
        guard frameNo == 0, !watchdogInternal, !configOpen, isAnimating else { return }
        watchdogInternal = true
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = isPreview ? 20 : 30
    }

    private func ensureMtkLayout() {
        let size = bounds.size
        guard size.width >= 10, size.height >= 10 else { return }
        mtkView.frame = NSRect(origin: .zero, size: size)
        applyPresentationDrawable()
        layoutFpsHud()
    }

    /// Cap the drawable at 1280 on the long edge (full presentation, not half).
    private func applyPresentationDrawable() {
        guard let mtkView, !isPreview else { return }
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let fullW = mtkView.bounds.width * backing
        let fullH = mtkView.bounds.height * backing
        guard fullW >= 4, fullH >= 4 else { return }

        let maxEdge: CGFloat = 1280
        let longEdge = max(fullW, fullH)
        var w = fullW
        var h = fullH
        if longEdge > maxEdge {
            let s = maxEdge / longEdge
            w *= s
            h *= s
        }

        let newSize = NSSize(
            width: max(2, floor(w)),
            height: max(2, floor(h))
        )
        mtkView.autoResizeDrawable = false
        if Int(mtkView.drawableSize.width) != Int(newSize.width)
            || Int(mtkView.drawableSize.height) != Int(newSize.height) {
            mtkView.drawableSize = newSize
        }
        mtkView.layer?.magnificationFilter = .linear
        mtkView.layer?.minificationFilter = .linear
    }

    private func ensureDiscreteMetalDeviceIfNeeded() {
        guard let mtkView, !gpuUpgradeInFlight else { return }
        let hasDiscrete = MTLCopyAllDevices().contains { !$0.isLowPower }
        let current = mtkView.device
        let needsSwitch = current == nil
            || (hasDiscrete && current?.isLowPower == true)
            || renderer == nil
        guard needsSwitch else { return }

        gpuUpgradeInFlight = true
        MetalDevicePicker.preferredReadyAsync(timeoutSeconds: isPreview ? 0.5 : 2.0) { [weak self] device in
            guard let self, let mtkView = self.mtkView else { return }
            self.gpuUpgradeInFlight = false
            guard let device else { return }
            if mtkView.device?.registryID == device.registryID, self.renderer != nil {
                return
            }
            mtkView.device = device
            mtkView.delegate = nil
            if let newRenderer = Renderer(mtkView: mtkView, isPreview: self.isPreview) {
                self.renderer = newRenderer
                mtkView.delegate = newRenderer
            }
            self.layoutFpsHud()
        }
    }

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let controller = ConfigureSheetController(owner: self)
        sheetController = controller
        configOpen = true
        if watchdogInternal {
            mtkView?.isPaused = true
        }
        return controller.window
    }

    func configureSheetDidClose() {
        guard configOpen else { return }
        configOpen = false
        sheetController = nil
        renderer?.reloadPreferences()
        applyHudVisibility()
        if watchdogInternal {
            mtkView?.isPaused = false
        }
    }

    private func installFpsHud() {
        guard fpsLabel == nil else { return }

        // Sibling of MTKView (not a subview): Metal covers MTKView children.
        let pad: CGFloat = isPreview ? 4 : 10
        let height: CGFloat = isPreview ? 18 : 24
        let label = NSTextField(frame: NSRect(x: pad, y: pad, width: 200, height: height))
        label.font = NSFont.monospacedDigitSystemFont(ofSize: isPreview ? 10 : 13, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor(white: 0, alpha: 0.65)
        label.drawsBackground = true
        label.isBordered = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = " … fps "
        label.wantsLayer = true
        label.layer?.zPosition = 10_000
        label.autoresizingMask = [.width, .maxYMargin]
        addSubview(label, positioned: .above, relativeTo: mtkView)
        fpsLabel = label

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameStats(_:)),
            name: Renderer.statsNotification,
            object: nil
        )
        layoutFpsHud()
        applyHudVisibility()
    }

    private func layoutFpsHud() {
        guard let fpsLabel else { return }
        let pad: CGFloat = isPreview ? 4 : 10
        let height: CGFloat = isPreview ? 18 : 24
        let host = bounds.width >= 10 ? bounds : (mtkView?.bounds ?? bounds)
        let width = max(120, host.width - pad * 2)
        // Non-flipped: origin bottom-left → place near top.
        let y = max(pad, host.height - height - pad)
        fpsLabel.frame = NSRect(x: pad, y: y, width: width, height: height)
        addSubview(fpsLabel, positioned: .above, relativeTo: mtkView)
        fpsLabel.layer?.zPosition = 10_000
    }

    private func applyHudVisibility() {
        let show = Defaults.readShowHud()
        layoutFpsHud()
        fpsLabel?.isHidden = !show
        if show {
            hudFrames = 0
            hudWindowStart = 0
            if fpsLabel?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty != false {
                fpsLabel?.stringValue = " … fps "
            }
        }
    }

    private func tickHud() {
        guard Defaults.readShowHud(), fpsLabel != nil else { return }
        let status = renderer?.hudStatus
        if let status {
            lastHudFormula = status.formula
            lastHudPath = status.path
        }
        let now = CACurrentMediaTime()
        if hudWindowStart == 0 {
            hudWindowStart = now
            hudFrames = 0
        }
        hudFrames += 1
        let dt = now - hudWindowStart
        guard dt >= 0.4 else { return }
        let fps = Double(hudFrames) / dt
        hudFrames = 0
        hudWindowStart = now
        updateHudText(fps: fps, gpuMs: 0, dropped: 0)
    }

    private func updateHudText(fps: Double, gpuMs: Double, dropped: Double) {
        layoutFpsHud()
        var text = String(format: "%.1f fps  ·  Ziel 30", fps)
        if gpuMs >= 0.5 {
            text += String(format: "  ·  GPU %.0f ms", gpuMs)
        }
        if dropped >= 0.5 {
            text += String(format: "  ·  −%.0f dropped/s", dropped)
        }
        if !lastHudFormula.isEmpty {
            text += "  ·  \(lastHudFormula)"
            if !lastHudPath.isEmpty {
                text += " · \(lastHudPath)"
            }
        }
        fpsLabel?.stringValue = " \(text) "
        fpsLabel?.isHidden = false
    }

    @objc private func handleFrameStats(_ note: Notification) {
        let show = Defaults.readShowHud()
        fpsLabel?.isHidden = !show
        guard show, let fps = note.userInfo?["fps"] as? Double else { return }
        if let formula = note.userInfo?["formula"] as? String, !formula.isEmpty {
            lastHudFormula = formula
        }
        if let path = note.userInfo?["path"] as? String, !path.isEmpty {
            lastHudPath = path
        }
        let gpuMs = note.userInfo?["gpuMs"] as? Double ?? 0
        let dropped = note.userInfo?["dropped"] as? Double ?? 0
        updateHudText(fps: fps, gpuMs: gpuMs, dropped: dropped)
    }

    func commitConfiguration(formula: String, palette: String, speed: Int, showHud: Bool) {
        Defaults.writeFormula(formula)
        Defaults.writePalette(palette)
        Defaults.writeSpeedPercent(speed)
        Defaults.writeShowHud(showHud)
        applyHudVisibility()
        renderer?.reloadPreferences()
    }
}
