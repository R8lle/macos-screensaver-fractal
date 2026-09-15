import simd

/// One deep-zoom location. `parameter` is formula-specific (Julia `c`; unused for Mandelbrot).
struct ZoomTarget {
    let center: SIMD2<Double>
    let minScale: Double
    let parameter: SIMD2<Double>

    init(center: SIMD2<Double>, minScale: Double, parameter: SIMD2<Double> = .zero) {
        self.center = center
        self.minScale = minScale
        self.parameter = parameter
    }
}

/// Per-formula knobs. New fractals can change zoom, TAA, or iteration budget
/// without touching the renderer loop.
struct FormulaTuning {
    var overviewScale: Double = 1.45
    var zoomRate: Double = 0.07
    /// History weight in TAA. Higher lets the 4-frame 4×4 lattice settle on filaments.
    var taaBlend: Float = 0.74
    var maxIterCap: Int = 800
}

/// GPU formula id — keep in sync with `Shaders/Shaders.metal`.
enum FormulaShaderID: UInt32 {
    case mandelbrot = 0
    case julia = 1
    case burningShip = 2
}

/// A zoomable fractal. Add a new type, register it in `FormulaCatalog.all`,
/// and add a matching branch in the Metal iterate loop.
protocol FractalFormula {
    var id: String { get }
    var displayName: String { get }
    var shaderID: FormulaShaderID { get }
    var tuning: FormulaTuning { get }
    var targets: [ZoomTarget] { get }

    func fillOrbit(
        target: ZoomTarget,
        maxIter: Int,
        into ptr: UnsafeMutablePointer<SIMD4<Float>>,
        capacity: Int
    ) -> Int

    /// True if this view-offset from the zoom center escapes (not interior).
    func escapes(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Bool
}

enum FormulaCatalog {
    static let all: [FractalFormula] = [
        MandelbrotFormula(),
        JuliaFormula(),
        BurningShipFormula(),
    ]

    static var choices: [(id: String, displayName: String)] {
        all.map { ($0.id, $0.displayName) }
    }

    static func named(_ id: String) -> FractalFormula {
        all.first { $0.id == id } ?? MandelbrotFormula()
    }
}

enum OrbitMath {
    static func split(_ x: Double) -> SIMD2<Float> {
        let hi = Float(x)
        let lo = Float(x - Double(hi))
        return SIMD2(hi, lo)
    }

    static func store(_ z: SIMD2<Double>, at ptr: UnsafeMutablePointer<SIMD4<Float>>, index: Int) {
        let zx = split(z.x)
        let zy = split(z.y)
        ptr[index] = SIMD4(zx.x, zx.y, zy.x, zy.y)
    }
}

struct MandelbrotFormula: FractalFormula {
    let id = "mandelbrot"
    let displayName = "Mandelbrot"
    let shaderID = FormulaShaderID.mandelbrot
    let tuning = FormulaTuning()
    let targets: [ZoomTarget] = [
        ZoomTarget(center: SIMD2(-0.743_643_887_037_151, 0.131_825_904_205_330), minScale: 1.0e-10),
        ZoomTarget(center: SIMD2(-0.160_701_35, 1.037_566_5), minScale: 2.0e-10),
        ZoomTarget(center: SIMD2(-1.250_66, 0.020_12), minScale: 1.5e-10),
        ZoomTarget(center: SIMD2(-0.745_3, 0.112_7), minScale: 1.0e-10),
        ZoomTarget(center: SIMD2(-0.113, 0.6449), minScale: 2.0e-10),
        ZoomTarget(center: SIMD2(-1.768_778_8, -0.001_738_9), minScale: 1.5e-10),
    ]

    func fillOrbit(
        target: ZoomTarget,
        maxIter: Int,
        into ptr: UnsafeMutablePointer<SIMD4<Float>>,
        capacity: Int
    ) -> Int {
        var z = SIMD2<Double>(repeating: 0)
        let c = target.center
        var count = 0
        let limit = min(maxIter, capacity)
        while count < limit {
            OrbitMath.store(z, at: ptr, index: count)
            count += 1
            if z.x * z.x + z.y * z.y > 256 { break }
            let x = z.x * z.x - z.y * z.y + c.x
            let y = 2 * z.x * z.y + c.y
            z = SIMD2(x, y)
        }
        return count
    }

    func escapes(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Bool {
        let c = target.center + offset
        var z = SIMD2<Double>(repeating: 0)
        for _ in 0..<maxIter {
            if z.x * z.x + z.y * z.y > 256 { return true }
            let x = z.x * z.x - z.y * z.y + c.x
            let y = 2 * z.x * z.y + c.y
            z = SIMD2(x, y)
        }
        return false
    }
}

struct JuliaFormula: FractalFormula {
    let id = "julia"
    let displayName = "Julia"
    let shaderID = FormulaShaderID.julia
    let tuning = FormulaTuning()
    let targets: [ZoomTarget] = [
        ZoomTarget(center: SIMD2(-0.15, 0.15), minScale: 2.0e-10, parameter: SIMD2(-0.8, 0.156)),
        ZoomTarget(center: SIMD2(-0.2, 0.55), minScale: 2.0e-10, parameter: SIMD2(-0.123, 0.745)),
        ZoomTarget(center: SIMD2(0.0, 0.0), minScale: 1.5e-10, parameter: SIMD2(-0.7269, 0.1889)),
        ZoomTarget(center: SIMD2(0.35, 0.35), minScale: 2.0e-10, parameter: SIMD2(-0.4, 0.6)),
        ZoomTarget(center: SIMD2(0.0, 0.0), minScale: 1.5e-10, parameter: SIMD2(0.285, 0.01)),
    ]

    func fillOrbit(
        target: ZoomTarget,
        maxIter: Int,
        into ptr: UnsafeMutablePointer<SIMD4<Float>>,
        capacity: Int
    ) -> Int {
        var z = target.center
        let c = target.parameter
        var count = 0
        let limit = min(maxIter, capacity)
        while count < limit {
            OrbitMath.store(z, at: ptr, index: count)
            count += 1
            if z.x * z.x + z.y * z.y > 256 { break }
            let x = z.x * z.x - z.y * z.y + c.x
            let y = 2 * z.x * z.y + c.y
            z = SIMD2(x, y)
        }
        return count
    }

    func escapes(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Bool {
        var z = target.center + offset
        let c = target.parameter
        for _ in 0..<maxIter {
            if z.x * z.x + z.y * z.y > 256 { return true }
            let x = z.x * z.x - z.y * z.y + c.x
            let y = 2 * z.x * z.y + c.y
            z = SIMD2(x, y)
        }
        return false
    }
}

struct BurningShipFormula: FractalFormula {
    let id = "burningShip"
    let displayName = "Burning Ship"
    let shaderID = FormulaShaderID.burningShip
    let tuning = FormulaTuning()
    let targets: [ZoomTarget] = [
        ZoomTarget(center: SIMD2(-1.76, 0.03), minScale: 1.5e-10),
        ZoomTarget(center: SIMD2(-1.768, 0.0055), minScale: 1.0e-10),
        ZoomTarget(center: SIMD2(-1.861, 0.005), minScale: 2.0e-10),
        ZoomTarget(center: SIMD2(-1.627, 0.015), minScale: 2.0e-10),
        ZoomTarget(center: SIMD2(-1.775, 0.01), minScale: 1.5e-10),
    ]

    func fillOrbit(
        target: ZoomTarget,
        maxIter: Int,
        into ptr: UnsafeMutablePointer<SIMD4<Float>>,
        capacity: Int
    ) -> Int {
        var z = SIMD2<Double>(repeating: 0)
        let c = target.center
        var count = 0
        let limit = min(maxIter, capacity)
        while count < limit {
            OrbitMath.store(z, at: ptr, index: count)
            count += 1
            if z.x * z.x + z.y * z.y > 256 { break }
            let ax = abs(z.x)
            let ay = abs(z.y)
            z = SIMD2(ax * ax - ay * ay + c.x, 2 * ax * ay + c.y)
        }
        return count
    }

    func escapes(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Bool {
        let c = target.center + offset
        var z = SIMD2<Double>(repeating: 0)
        for _ in 0..<maxIter {
            if z.x * z.x + z.y * z.y > 256 { return true }
            let ax = abs(z.x)
            let ay = abs(z.y)
            z = SIMD2(ax * ax - ay * ay + c.x, 2 * ax * ay + c.y)
        }
        return false
    }
}
