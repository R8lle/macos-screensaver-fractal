import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

/// Fullscreen fractal zoom. Switches to the next interesting point
/// after a deep zoom, with a short fade.
///
/// CPU builds a double-precision reference orbit (stored as DS float4);
/// the GPU only iterates the per-pixel float delta. 2×2 of a 4×4 lattice
/// per frame; TAA accumulates the other phases (filament AA without 4×4 cost).
final class Renderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var scale: Float
        var aspect: Float
        var param: SIMD2<Float>
        var jitter: SIMD2<Float>
        var palette: UInt32
        var maxIter: UInt32
        var refLen: UInt32
        var formula: UInt32
        var fade: Float
        var pad: Float
    }

    private struct TAAUniforms {
        var ratio: Float
        var blend: Float
        var valid: Float
        var keep: Float
    }

    static let statsNotification = Notification.Name("de.r8lle.screensaver.fractal.stats")

    private static let fadeSeconds: Double = 2.2
    private static let maxOrbit = 1024
    private static let maxInFlight = 2

    private let inflightLock = NSLock()
    private var inflight = 0
    private let statsLock = NSLock()
    private var statsWindowStart: CFTimeInterval = 0
    private var presentedInWindow = 0
    private var droppedInWindow = 0
    private var gpuSecondsInWindow = 0.0
    private var gpuSamplesInWindow = 0
    private var statusFormula = ""
    private var statusPath = ""

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let fractalPipeline: MTLRenderPipelineState
    private let taaPipeline: MTLRenderPipelineState
    private let blitPipeline: MTLRenderPipelineState
    private let hudPipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState
    private var uniformBuffer: MTLBuffer
    private var taaUniformBuffer: MTLBuffer
    private var orbitBuffer: MTLBuffer
    private var hudRectBuffer: MTLBuffer?

    private var freshTexture: MTLTexture?
    private var historyA: MTLTexture?
    private var historyB: MTLTexture?
    private var writeHistoryA = true
    private var hudTexture: MTLTexture?
    private var hudDrawnText = ""
    private var lastHudRaster: CFTimeInterval = 0
    private var showHud = Defaults.defaultShowHud
    private var staleProbeBusy = false

    private let isPreview: Bool
    private var formula: FractalFormula = MandelbrotFormula()
    private var formulaModeAll = false
    private var paletteModeAll = false
    private var activePaletteId = "r8lle"
    private var scale: Double = 1.45
    private var lastScale: Double = 0
    private var targetIndex = 0
    private var lastTargetIndex = 0
    private var lastTime: CFTimeInterval = 0
    private var fadingOut = false
    private var fade: Double = 1
    private var palette: UInt32 = 0
    private var speedPercent = Defaults.defaultSpeed
    private var frameIndex: UInt32 = 0
    private var interiorSince: CFTimeInterval = 0
    private var lastStaleCheck: CFTimeInterval = 0
    private var lastStaleSignature: [Int8] = []
    private var lastStaleScale: Double = 0

    init?(mtkView: MTKView, isPreview: Bool) {
        guard let device = mtkView.device else { return nil }
        guard let queue = device.makeCommandQueue() else { return nil }
        let bundle = Bundle(for: FractalSaverView.self)
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            NSLog("[FractalSaver] default Metal library missing")
            return nil
        }
        guard let vs = library.makeFunction(name: "fractal_vs"),
              let fs = library.makeFunction(name: "fractal_fs"),
              let blitVS = library.makeFunction(name: "blit_vs"),
              let taaFS = library.makeFunction(name: "taa_fs"),
              let blitFS = library.makeFunction(name: "blit_fs") else {
            NSLog("[FractalSaver] shader functions missing")
            return nil
        }

        let fractalDesc = MTLRenderPipelineDescriptor()
        fractalDesc.vertexFunction = vs
        fractalDesc.fragmentFunction = fs
        fractalDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        let taaDesc = MTLRenderPipelineDescriptor()
        taaDesc.vertexFunction = blitVS
        taaDesc.fragmentFunction = taaFS
        taaDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        let blitDesc = MTLRenderPipelineDescriptor()
        blitDesc.vertexFunction = blitVS
        blitDesc.fragmentFunction = blitFS
        blitDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        // HUD is optional — never block fractal init if overlay shaders fail.
        var builtHud: MTLRenderPipelineState?
        if let hudVS = library.makeFunction(name: "hud_vs"),
           let hudFS = library.makeFunction(name: "hud_fs") {
            let hudDesc = MTLRenderPipelineDescriptor()
            hudDesc.vertexFunction = hudVS
            hudDesc.fragmentFunction = hudFS
            hudDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            if let att = hudDesc.colorAttachments[0] {
                att.isBlendingEnabled = true
                att.rgbBlendOperation = .add
                att.alphaBlendOperation = .add
                att.sourceRGBBlendFactor = .sourceAlpha
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                att.sourceAlphaBlendFactor = .one
                att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            builtHud = try? device.makeRenderPipelineState(descriptor: hudDesc)
        }
        if builtHud == nil {
            NSLog("[FractalSaver] HUD pipeline unavailable — fps overlay disabled")
        }

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge

        let orbitBytes = Self.maxOrbit * MemoryLayout<SIMD4<Float>>.stride
        guard let fractalPipeline = try? device.makeRenderPipelineState(descriptor: fractalDesc),
              let taaPipeline = try? device.makeRenderPipelineState(descriptor: taaDesc),
              let blitPipeline = try? device.makeRenderPipelineState(descriptor: blitDesc),
              let sampler = device.makeSamplerState(descriptor: sampDesc),
              let uniforms = device.makeBuffer(
                length: MemoryLayout<Uniforms>.stride, options: .storageModeShared
              ),
              let taaUniforms = device.makeBuffer(
                length: MemoryLayout<TAAUniforms>.stride, options: .storageModeShared
              ),
              let orbit = device.makeBuffer(length: orbitBytes, options: .storageModeShared) else {
            NSLog("[FractalSaver] pipeline state failed")
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.fractalPipeline = fractalPipeline
        self.taaPipeline = taaPipeline
        self.blitPipeline = blitPipeline
        self.hudPipeline = builtHud
        self.sampler = sampler
        self.uniformBuffer = uniforms
        self.taaUniformBuffer = taaUniforms
        self.orbitBuffer = orbit
        self.hudRectBuffer = builtHud == nil
            ? nil
            : device.makeBuffer(
                length: MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared
            )
        self.isPreview = isPreview
        super.init()
        reloadPreferences()
        if formulaModeAll {
            formula = FormulaCatalog.random(avoiding: nil)
        }
        pickRandomTarget(avoiding: nil)
        lastTargetIndex = targetIndex
        scale = formula.tuning.overviewScale
        if showHud {
            hudTexture = Self.makePlaceholderHudTexture(device: device)
        }
    }

    func reloadPreferences() {
        formulaModeAll = Defaults.isAllFormulas()
        paletteModeAll = Defaults.isAllPalettes()
        speedPercent = Defaults.readSpeedPercent()
        showHud = Defaults.readShowHud()
        if !showHud {
            hudTexture = nil
            hudDrawnText = ""
        } else if hudTexture == nil {
            hudTexture = Self.makePlaceholderHudTexture(device: device)
        }

        if paletteModeAll {
            applyPalette(Defaults.randomPaletteId(avoiding: activePaletteId))
        } else {
            applyPalette(Defaults.readPalette())
        }

        if formulaModeAll {
            // Stay on the current formula until the next fade advances.
        } else {
            let next = FormulaCatalog.named(Defaults.readFormula())
            if next.id != formula.id {
                formula = next
                pickRandomTarget(avoiding: nil)
                lastTargetIndex = targetIndex
                scale = next.tuning.overviewScale
                lastScale = 0
                fadingOut = false
                fade = 1
                resetStaleTracking()
            } else {
                formula = next
            }
        }
    }

    private func applyPalette(_ id: String) {
        let concrete = id == Defaults.allId ? Defaults.randomPaletteId() : id
        activePaletteId = concrete
        palette = Defaults.paletteIndex(for: concrete)
    }

    /// After a finished zoom fades out: maybe new formula, new path, new palette.
    private func advanceToNextFractal() {
        if formulaModeAll {
            formula = FormulaCatalog.random(avoiding: formula.id)
            pickRandomTarget(avoiding: nil)
        } else {
            pickRandomTarget(avoiding: targetIndex)
        }
        if paletteModeAll {
            applyPalette(Defaults.randomPaletteId(avoiding: activePaletteId))
        }
        lastTargetIndex = targetIndex
        scale = formula.tuning.overviewScale
        fadingOut = false
        fade = 1
        lastScale = 0
        resetStaleTracking()
    }

    /// Random zoom path. Prefer a different target than `avoiding` when possible.
    private func pickRandomTarget(avoiding: Int?) {
        let count = formula.targets.count
        guard count > 0 else {
            targetIndex = 0
            return
        }
        guard count > 1, let avoiding, avoiding >= 0, avoiding < count else {
            targetIndex = Int.random(in: 0..<count)
            return
        }
        var next = Int.random(in: 0..<count)
        if next == avoiding {
            next = (next + 1 + Int.random(in: 0..<(count - 1))) % count
        }
        targetIndex = next
    }

    /// Current formula/path label for the on-screen HUD.
    var hudStatus: (formula: String, path: String) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (statusFormula, statusPath)
    }

    func beginRandomPath() {
        if formulaModeAll {
            formula = FormulaCatalog.random(avoiding: formula.id)
        }
        pickRandomTarget(avoiding: targetIndex)
        if paletteModeAll {
            applyPalette(Defaults.randomPaletteId(avoiding: activePaletteId))
        }
        lastTargetIndex = targetIndex
        scale = formula.tuning.overviewScale
        lastScale = 0
        fadingOut = false
        fade = 1
        resetStaleTracking()
        lastTime = 0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        freshTexture = nil
        historyA = nil
        historyB = nil
        lastScale = 0
    }

    private func releaseInFlight() {
        inflightLock.lock()
        inflight = max(0, inflight - 1)
        inflightLock.unlock()
    }

    private func noteDroppedFrame() {
        statsLock.lock()
        droppedInWindow += 1
        publishStatsIfNeededLocked()
        statsLock.unlock()
    }

    private func notePresentedFrame() {
        statsLock.lock()
        presentedInWindow += 1
        publishStatsIfNeededLocked()
        statsLock.unlock()
    }

    private func noteGpuSeconds(_ seconds: Double) {
        guard seconds > 0, seconds < 2 else { return }
        statsLock.lock()
        gpuSecondsInWindow += seconds
        gpuSamplesInWindow += 1
        statsLock.unlock()
    }

    private func publishStatsIfNeededLocked() {
        let now = CACurrentMediaTime()
        if statsWindowStart == 0 {
            statsWindowStart = now
            return
        }
        let dt = now - statsWindowStart
        guard dt >= 0.5 else { return }
        let fps = Double(presentedInWindow) / dt
        let droppedPerSec = Double(droppedInWindow) / dt
        let gpuMs = gpuSamplesInWindow > 0
            ? (gpuSecondsInWindow / Double(gpuSamplesInWindow)) * 1000
            : 0
        let formulaName = statusFormula
        let pathName = statusPath
        presentedInWindow = 0
        droppedInWindow = 0
        gpuSecondsInWindow = 0
        gpuSamplesInWindow = 0
        statsWindowStart = now

        var text = String(format: "%.1f fps", fps)
        if gpuMs >= 0.5 {
            text += String(format: "  ·  GPU %.0f ms", gpuMs)
        }
        if droppedPerSec >= 0.5 {
            text += String(format: "  ·  −%.0f dropped/s", droppedPerSec)
        }
        if !formulaName.isEmpty {
            text += "  ·  \(formulaName)"
            if !pathName.isEmpty {
                text += " · \(pathName)"
            }
        }
        let hudLine = text

        DispatchQueue.main.async { [weak self] in
            self?.updateHudTexture(text: hudLine, force: false)
            NotificationCenter.default.post(
                name: Renderer.statsNotification,
                object: nil,
                userInfo: [
                    "fps": fps,
                    "gpuMs": gpuMs,
                    "dropped": droppedPerSec,
                    "formula": formulaName,
                    "path": pathName,
                ]
            )
        }
    }

    func draw(in view: MTKView) {
        inflightLock.lock()
        let busy = inflight >= Self.maxInFlight
        if !busy { inflight += 1 }
        inflightLock.unlock()
        guard !busy else {
            noteDroppedFrame()
            return
        }

        let now = CACurrentMediaTime()
        advanceZoom(now: now)

        let drawableSize = view.drawableSize
        guard drawableSize.width >= 2, drawableSize.height >= 2 else {
            releaseInFlight()
            return
        }
        guard let fresh = ensureTexture(&freshTexture, size: drawableSize),
              let histA = ensureTexture(&historyA, size: drawableSize),
              let histB = ensureTexture(&historyB, size: drawableSize) else {
            releaseInFlight()
            return
        }

        let targets = formula.targets
        guard !targets.isEmpty else {
            releaseInFlight()
            return
        }
        if targetIndex >= targets.count { targetIndex = 0 }
        let target = targets[targetIndex]
        statsLock.lock()
        statusFormula = formula.displayName
        statusPath = target.name
        statsLock.unlock()

        let cap = formula.tuning.maxIterCap
        let rawIters = 120.0 + max(0, -log10(max(scale, 1e-12))) * 75.0
        let iters = UInt32(min(cap, max(80, Int(rawIters))))
        let refLen = fillOrbit(target: target, maxIter: Int(iters))
        scheduleStaleCheck(
            now: now,
            target: target,
            aspect: drawableSize.width / drawableSize.height,
            maxIter: Int(iters)
        )

        var uniforms = Uniforms(
            resolution: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            scale: Float(scale),
            aspect: Float(drawableSize.width / drawableSize.height),
            param: SIMD2(Float(target.parameter.x), Float(target.parameter.y)),
            jitter: Self.temporalJitter(frameIndex),
            palette: palette,
            maxIter: iters,
            refLen: refLen,
            formula: formula.shaderID.rawValue,
            fade: Float(fade),
            pad: 0
        )
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        let histRead = writeHistoryA ? histB : histA
        let histWrite = writeHistoryA ? histA : histB
        let taaValid = lastScale > 0
            && targetIndex == lastTargetIndex
            && fade > 0.02
        var taa = TAAUniforms(
            ratio: taaValid ? Float(scale / lastScale) : 1,
            blend: formula.tuning.taaBlend,
            valid: taaValid ? 1 : 0,
            keep: 1
        )
        memcpy(taaUniformBuffer.contents(), &taa, MemoryLayout<TAAUniforms>.stride)

        guard let drawable = view.currentDrawable,
              let cmd = commandQueue.makeCommandBuffer() else {
            releaseInFlight()
            return
        }
        cmd.addCompletedHandler { [weak self] buf in
            let gpu = buf.gpuEndTime - buf.gpuStartTime
            self?.noteGpuSeconds(gpu)
            self?.releaseInFlight()
        }

        let fractalPass = MTLRenderPassDescriptor()
        fractalPass.colorAttachments[0].texture = fresh
        fractalPass.colorAttachments[0].loadAction = .dontCare
        fractalPass.colorAttachments[0].storeAction = .store
        guard let fractalEnc = cmd.makeRenderCommandEncoder(descriptor: fractalPass) else {
            cmd.commit()
            return
        }
        fractalEnc.setRenderPipelineState(fractalPipeline)
        fractalEnc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        fractalEnc.setFragmentBuffer(orbitBuffer, offset: 0, index: 1)
        fractalEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        fractalEnc.endEncoding()

        let taaPass = MTLRenderPassDescriptor()
        taaPass.colorAttachments[0].texture = histWrite
        taaPass.colorAttachments[0].loadAction = .dontCare
        taaPass.colorAttachments[0].storeAction = .store
        guard let taaEnc = cmd.makeRenderCommandEncoder(descriptor: taaPass) else {
            cmd.commit()
            return
        }
        taaEnc.setRenderPipelineState(taaPipeline)
        taaEnc.setFragmentBuffer(taaUniformBuffer, offset: 0, index: 0)
        taaEnc.setFragmentTexture(fresh, index: 0)
        taaEnc.setFragmentTexture(histRead, index: 1)
        taaEnc.setFragmentSamplerState(sampler, index: 0)
        taaEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        taaEnc.endEncoding()

        let screenPass = MTLRenderPassDescriptor()
        screenPass.colorAttachments[0].texture = drawable.texture
        screenPass.colorAttachments[0].loadAction = .dontCare
        screenPass.colorAttachments[0].storeAction = .store
        guard let screenEnc = cmd.makeRenderCommandEncoder(descriptor: screenPass) else {
            cmd.commit()
            return
        }
        screenEnc.setRenderPipelineState(blitPipeline)
        screenEnc.setFragmentTexture(histWrite, index: 0)
        screenEnc.setFragmentSamplerState(sampler, index: 0)
        screenEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if showHud, let hudPipeline, let hudRectBuffer, let hudTexture {
            let dw = Float(drawableSize.width)
            let dh = Float(drawableSize.height)
            // On-screen size is a fraction of the frame — NOT texture pixel size
            // (drawable is upscaled to the display, so 1:1 texture px looks huge).
            let th = dh * (isPreview ? 0.04 : 0.02)
            let aspect = Float(hudTexture.width) / max(Float(hudTexture.height), 1)
            let tw = min(th * aspect, dw * 0.92)
            let pad = dh * 0.01
            let x0 = -1 + 2 * pad / dw
            let y1 = 1 - 2 * pad / dh
            let x1 = x0 + 2 * tw / dw
            let y0 = y1 - 2 * th / dh
            var rect = SIMD4<Float>(x0, y0, x1, y1)
            memcpy(hudRectBuffer.contents(), &rect, MemoryLayout<SIMD4<Float>>.stride)
            screenEnc.setRenderPipelineState(hudPipeline)
            screenEnc.setVertexBuffer(hudRectBuffer, offset: 0, index: 0)
            screenEnc.setFragmentTexture(hudTexture, index: 0)
            screenEnc.setFragmentSamplerState(sampler, index: 0)
            screenEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        screenEnc.endEncoding()

        cmd.present(drawable)
        cmd.commit()
        notePresentedFrame()

        writeHistoryA.toggle()
        lastScale = scale
        lastTargetIndex = targetIndex
        frameIndex &+= 1
    }

    private func updateHudTexture(text: String, force: Bool) {
        guard showHud, hudPipeline != nil else { return }
        let now = CACurrentMediaTime()
        if !force {
            guard text != hudDrawnText else { return }
        }
        guard let newTexture = Self.makeHudTexture(
            device: device,
            text: text,
            preview: isPreview
        ) else {
            return
        }
        hudTexture = newTexture
        hudDrawnText = text
        lastHudRaster = now
    }

    private static func makePlaceholderHudTexture(device: MTLDevice) -> MTLTexture? {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0
            pixels[i + 1] = 0
            pixels[i + 2] = 0
            pixels[i + 3] = 180
        }
        return uploadHudTexture(device: device, width: width, height: height, pixels: &pixels)
    }

    private static func makeHudTexture(
        device: MTLDevice,
        text: String,
        preview: Bool
    ) -> MTLTexture? {
        let fontSize: CGFloat = preview ? 13 : 16
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: " \(text) ", attributes: attrs)
        let textSize = attributed.size()
        let padX: CGFloat = preview ? 6 : 8
        let padY: CGFloat = preview ? 3 : 4
        let width = max(32, Int(ceil(textSize.width + padX * 2)))
        let height = max(16, Int(ceil(textSize.height + padY * 2)))
        var pixels = [UInt8](repeating: 0, count: height * width * 4)
        let bytesPerRow = width * 4

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.75)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        attributed.draw(at: NSPoint(x: padX, y: padY))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        return uploadHudTexture(device: device, width: width, height: height, pixels: &pixels)
    }

    private static func uploadHudTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixels: inout [UInt8]
    ) -> MTLTexture? {
        let bytesPerRow = width * 4
        func make(_ mode: MTLStorageMode) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = mode
            guard let texture = device.makeTexture(descriptor: desc) else { return nil }
            pixels.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: bytesPerRow
                )
            }
            return texture
        }
        // Managed is the portable CPU-write path on discrete macOS GPUs.
        return make(.managed) ?? make(.shared)
    }

    /// 4-frame phase of a 4×4 pixel lattice (cell 0.25 px). Combined with the
    /// shader's 2×2 (spacing 0.5) this covers all 16 locations over time.
    private static let jitterPattern: [SIMD2<Float>] = [
        SIMD2(0.00, 0.00),
        SIMD2(0.25, 0.00),
        SIMD2(0.00, 0.25),
        SIMD2(0.25, 0.25),
    ]

    private static func temporalJitter(_ index: UInt32) -> SIMD2<Float> {
        jitterPattern[Int(index % UInt32(jitterPattern.count))]
    }

    private func ensureTexture(_ slot: inout MTLTexture?, size: CGSize) -> MTLTexture? {
        let w = Int(size.width)
        let h = Int(size.height)
        if let existing = slot, existing.width == w, existing.height == h {
            return existing
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc) else {
            NSLog("[FractalSaver] TAA texture alloc failed (%dx%d)", w, h)
            return nil
        }
        slot = texture
        lastScale = 0
        return texture
    }

    private func fillOrbit(target: ZoomTarget, maxIter: Int) -> UInt32 {
        let ptr = orbitBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxOrbit)
        let count = formula.fillOrbit(
            target: target,
            maxIter: maxIter,
            into: ptr,
            capacity: Self.maxOrbit
        )
        return UInt32(count)
    }

    private func advanceZoom(now: CFTimeInterval) {
        if lastTime == 0 {
            lastTime = now
            return
        }
        let dt = min(now - lastTime, 0.05)
        lastTime = now

        if fadingOut {
            fade -= dt / Self.fadeSeconds
            if fade <= 0 {
                advanceToNextFractal()
            }
            return
        }

        let speed = Double(speedPercent) / 100.0
        let zoomRate = formula.tuning.zoomRate * speed * (isPreview ? 1.15 : 1.0)
        scale *= exp(-zoomRate * dt)
        guard formula.targets.indices.contains(targetIndex) else { return }
        if scale <= formula.targets[targetIndex].minScale {
            fadingOut = true
        }
    }

    private func resetStaleTracking() {
        interiorSince = 0
        lastStaleCheck = 0
        lastStaleSignature = []
        lastStaleScale = 0
        staleProbeBusy = false
    }

    /// Runs off the draw thread so deep-zoom probes cannot steal frame time.
    private func scheduleStaleCheck(
        now: CFTimeInterval,
        target: ZoomTarget,
        aspect: Double,
        maxIter: Int
    ) {
        guard !fadingOut else { return }
        guard scale < 0.05 else {
            interiorSince = 0
            lastStaleSignature = []
            lastStaleScale = 0
            return
        }
        guard !staleProbeBusy, now - lastStaleCheck >= 0.4 else { return }
        lastStaleCheck = now
        staleProbeBusy = true

        let probeScale = scale
        let probeAspect = aspect
        // 48 iters was too coarse for Julia filaments → false "flat" aborts.
        let probeIters = min(96, maxIter)
        let probeTarget = target
        let formula = self.formula
        let prevSignature = lastStaleSignature
        let prevScale = lastStaleScale

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hx = probeScale * probeAspect * 0.45
            let hy = probeScale * 0.45
            let grid = 3
            let denom = Double(grid - 1)
            let bucketScale = max(probeIters, 1)
            var signature = [Int8]()
            signature.reserveCapacity(grid * grid)
            var bins = Set<Int>()
            var escapeIters: [Int] = []

            for gy in 0..<grid {
                for gx in 0..<grid {
                    let u = Double(gx) / denom * 2.0 - 1.0
                    let v = Double(gy) / denom * 2.0 - 1.0
                    if let iter = formula.escapeIteration(
                        offset: SIMD2(u * hx, v * hy),
                        target: probeTarget,
                        maxIter: probeIters
                    ) {
                        let bin = min(7, iter * 8 / bucketScale)
                        bins.insert(bin)
                        escapeIters.append(iter)
                        signature.append(Int8(bin))
                    } else {
                        signature.append(-1)
                    }
                }
            }

            // Flat = featureless. Mixed interior+escape is the *boundary* — keep zooming.
            // All-interior, or all-escape with only one bucket / tiny spread → abort.
            let interiorCount = signature.filter { $0 < 0 }.count
            let mixedBoundary = interiorCount > 0 && !escapeIters.isEmpty
            var isFlat = false
            if !mixedBoundary {
                if escapeIters.isEmpty {
                    isFlat = true // all interior → black
                } else if bins.count <= 1 {
                    isFlat = true // uniform exterior wash
                } else if let lo = escapeIters.min(), let hi = escapeIters.max() {
                    let mean = Double(escapeIters.reduce(0, +)) / Double(escapeIters.count)
                    isFlat = Double(hi - lo) <= max(8.0, mean * 0.12)
                }
            }
            let scaleMoved = prevScale <= 0 || prevScale / probeScale >= 1.12
            let sameLook = !prevSignature.isEmpty
                && prevSignature.count == signature.count
                && zip(prevSignature, signature).filter { $0 != $1 }.count <= 2
            let stagnant = isFlat || (scaleMoved && sameLook)

            DispatchQueue.main.async {
                guard let self, !self.fadingOut else { return }
                self.staleProbeBusy = false
                if scaleMoved {
                    self.lastStaleSignature = signature
                    self.lastStaleScale = probeScale
                }
                if stagnant {
                    let t = CACurrentMediaTime()
                    if self.interiorSince == 0 { self.interiorSince = t }
                    // Hold a bit longer so sparse-but-real filaments survive.
                    if t - self.interiorSince >= 1.2 {
                        self.fadingOut = true
                    }
                } else {
                    self.interiorSince = 0
                }
            }
        }
    }
}
