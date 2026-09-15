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

        installFpsHudIfNeeded()
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
        if watchdogInternal {
            mtkView?.isPaused = false
        }
    }

    private func installFpsHudIfNeeded() {
        guard ProcessInfo.processInfo.processName == "FractalTest" else { return }
        let label = NSTextField(labelWithString: "… fps")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor(white: 0, alpha: 0.45)
        label.drawsBackground = true
        label.isBordered = false
        label.isBezeled = false
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
        fpsLabel = label
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameStats(_:)),
            name: Renderer.statsNotification,
            object: nil
        )
    }

    @objc private func handleFrameStats(_ note: Notification) {
        guard let fps = note.userInfo?["fps"] as? Double else { return }
        let gpuMs = note.userInfo?["gpuMs"] as? Double ?? 0
        let dropped = note.userInfo?["dropped"] as? Double ?? 0
        var text = String(format: "%.1f fps  ·  Ziel 30", fps)
        if gpuMs >= 0.5 {
            text += String(format: "  ·  GPU %.0f ms", gpuMs)
        }
        if dropped >= 0.5 {
            text += String(format: "  ·  −%.0f dropped/s", dropped)
        }
        fpsLabel?.stringValue = " \(text) "
    }

    func commitConfiguration(formula: String, palette: String, speed: Int) {
        Defaults.writeFormula(formula)
        Defaults.writePalette(palette)
        Defaults.writeSpeedPercent(speed)
        renderer?.reloadPreferences()
    }
}
