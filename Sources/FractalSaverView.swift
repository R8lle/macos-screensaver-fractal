import Cocoa
import Metal
import MetalKit
import ScreenSaver

/// Bundle entry (`NSPrincipalClass`). Thin ScreenSaverView + MTKView shell.
@objc(FractalSaverView)
final class FractalSaverView: ScreenSaverView {
    private var mtkView: MTKView!
    private var renderer: Renderer?
    private var staticPreview: NSImageView?
    private var sheetController: ConfigureSheetController?
    private var gpuUpgradeInFlight = false
    private var configOpen = false
    private var frameNo = 0
    private var watchdogInternal = false

    private static let thumbnailPlaceholderSize = NSSize(width: 160, height: 100)
    private static let maxDrawableEdge: CGFloat = 1280

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

        var contentFrame = bounds
        if contentFrame.width < 10 || contentFrame.height < 10 {
            contentFrame = NSRect(
                origin: .zero,
                size: isPreview ? Self.thumbnailPlaceholderSize : NSSize(width: 800, height: 500)
            )
        }

        // System Settings hosts isPreview=true for the picker tile / Options
        // preview. A failed Metal draw there falls back to the blue swirl.
        // Use the bundled ScreenSaverThumbnail for all preview surfaces.
        if isPreview {
            let imageView = NSImageView(frame: contentFrame)
            imageView.image = Self.bundledThumbnailImage()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.autoresizingMask = [.width, .height]
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor.black.cgColor
            addSubview(imageView)
            staticPreview = imageView
            // Dummy MTKView so later full-screen paths stay simple if needed.
            let placeholder = MTKView(frame: .zero)
            placeholder.isHidden = true
            mtkView = placeholder
            return
        }

        let view = MTKView(frame: contentFrame)
        view.autoresizingMask = [.width, .height]
        view.device = MetalDevicePicker.preferredReady(timeoutSeconds: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 960, height: 540)
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
    }

    private static func bundledThumbnailImage() -> NSImage? {
        let bundle = Bundle(for: FractalSaverView.self)
        if let name = bundle.object(forInfoDictionaryKey: "ScreenSaverThumbnail") as? String,
           let img = bundle.image(forResource: name) {
            return img
        }
        return bundle.image(forResource: "thumbnail")
    }

    override func layout() {
        super.layout()
        if isPreview {
            let size = bounds.size
            if size.width >= 10, size.height >= 10 {
                staticPreview?.frame = NSRect(origin: .zero, size: size)
            }
            return
        }
        ensureMtkLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !isPreview else { return }
        guard window != nil else {
            if watchdogInternal {
                watchdogInternal = false
                mtkView?.isPaused = true
            }
            return
        }
        ensureDiscreteMetalDeviceIfNeeded()
        ensureMtkLayout()
        renderer?.reloadPreferences()
    }

    override func startAnimation() {
        super.startAnimation()
        guard !isPreview else { return }
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
        guard !isPreview, !configOpen else { return }
        frameNo += 1
        if watchdogInternal { return }
        mtkView.draw()
    }

    @objc private func watchdogCheckTicks() {
        guard !isPreview else { return }
        guard frameNo == 0, !watchdogInternal, !configOpen, isAnimating else { return }
        watchdogInternal = true
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 30
    }

    private func ensureMtkLayout() {
        guard !isPreview else { return }
        let size = bounds.size
        guard size.width >= 10, size.height >= 10 else { return }
        mtkView.frame = NSRect(origin: .zero, size: size)
        applyPresentationDrawable()
    }

    /// Cap the drawable at 1280 on the long edge (full presentation, not half).
    private func applyPresentationDrawable() {
        guard let mtkView, !isPreview else { return }
        mtkView.autoResizeDrawable = false
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let fullW = mtkView.bounds.width * backing
        let fullH = mtkView.bounds.height * backing
        guard fullW >= 4, fullH >= 4 else { return }

        let longEdge = max(fullW, fullH)
        var w = fullW
        var h = fullH
        if longEdge > Self.maxDrawableEdge {
            let s = Self.maxDrawableEdge / longEdge
            w *= s
            h *= s
        }

        let newSize = NSSize(
            width: max(2, floor(w)),
            height: max(2, floor(h))
        )
        if Int(mtkView.drawableSize.width) != Int(newSize.width)
            || Int(mtkView.drawableSize.height) != Int(newSize.height) {
            mtkView.drawableSize = newSize
        }
        mtkView.layer?.magnificationFilter = .linear
        mtkView.layer?.minificationFilter = .linear
    }

    private func ensureDiscreteMetalDeviceIfNeeded() {
        guard !isPreview, let mtkView, !gpuUpgradeInFlight else { return }
        let hasDiscrete = MTLCopyAllDevices().contains { !$0.isLowPower }
        let current = mtkView.device
        let needsSwitch = current == nil
            || (hasDiscrete && current?.isLowPower == true)
            || renderer == nil
        guard needsSwitch else { return }

        gpuUpgradeInFlight = true
        MetalDevicePicker.preferredReadyAsync(timeoutSeconds: 2.0) { [weak self] device in
            guard let self, let mtkView = self.mtkView else { return }
            self.gpuUpgradeInFlight = false
            guard let device else { return }
            if mtkView.device?.registryID == device.registryID, self.renderer != nil {
                return
            }
            mtkView.device = device
            mtkView.delegate = nil
            if let newRenderer = Renderer(mtkView: mtkView, isPreview: false) {
                self.renderer = newRenderer
                mtkView.delegate = newRenderer
            }
            self.ensureMtkLayout()
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

    func commitConfiguration(formula: String, palette: String, speed: Int, showHud: Bool) {
        Defaults.writeFormula(formula)
        Defaults.writePalette(palette)
        Defaults.writeSpeedPercent(speed)
        Defaults.writeShowHud(showHud)
        renderer?.reloadPreferences()
    }
}
