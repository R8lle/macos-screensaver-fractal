import simd

/// One deep-zoom location. `parameter` is formula-specific (Julia `c`; unused for Mandelbrot).
struct ZoomTarget {
    let name: String
    let center: SIMD2<Double>
    let minScale: Double
    let parameter: SIMD2<Double>

    init(name: String, center: SIMD2<Double>, minScale: Double, parameter: SIMD2<Double> = .zero) {
        self.name = name
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
    case tricorn = 3
    case burningShipJulia = 4
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

    /// Escape iteration count, or `nil` if still bounded after maxIter (interior).
    func escapeIteration(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Int?

    /// True if this view-offset from the zoom center escapes (not interior).
    func escapes(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Bool
}

extension FractalFormula {
    func escapes(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Bool {
        escapeIteration(offset: offset, target: target, maxIter: maxIter) != nil
    }
}

enum FormulaCatalog {
    static let all: [FractalFormula] = [
        MandelbrotFormula(),
        JuliaFormula(),
        BurningShipFormula(),
        TricornFormula(),
        BurningShipJuliaFormula(),
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
        ZoomTarget(name: "Seahorse Valley", center: SIMD2(-0.743_643_887_037_151, 0.131_825_904_205_330), minScale: 1.0e-10),
        ZoomTarget(name: "Seahorse Mouth", center: SIMD2(-0.759_856, 0.125_547), minScale: 2.0e-10),
        ZoomTarget(name: "Mutated Seahorse", center: SIMD2(-0.733, 0.288), minScale: 2.0e-10),
        ZoomTarget(name: "Northern Spire", center: SIMD2(-0.160_701_35, 1.037_566_5), minScale: 2.0e-10),
        ZoomTarget(name: "West Filament", center: SIMD2(-1.250_66, 0.020_12), minScale: 1.5e-10),
        ZoomTarget(name: "Double Spiral", center: SIMD2(-0.745_3, 0.112_7), minScale: 1.0e-10),
        ZoomTarget(name: "Upper Bulb Edge", center: SIMD2(-0.113, 0.6449), minScale: 2.0e-10),
        ZoomTarget(name: "Scepter Tip", center: SIMD2(-1.768_778_8, -0.001_738_9), minScale: 1.5e-10),
        ZoomTarget(name: "Elephant Valley", center: SIMD2(0.282, -0.01), minScale: 2.0e-10),
        ZoomTarget(name: "Elephant Cusp", center: SIMD2(0.298_33, 0.001_11), minScale: 2.0e-10),
        ZoomTarget(name: "Feigenbaum", center: SIMD2(-1.401_155, 0.0), minScale: 1.5e-10),
        ZoomTarget(name: "Period-3 Bulb", center: SIMD2(-0.101_1, 0.956_3), minScale: 2.0e-10),
        ZoomTarget(name: "North Tip", center: SIMD2(0.001_643_721_971_153, 0.822_467_633_298_876), minScale: 1.5e-10),
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

    func escapeIteration(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Int? {
        let c = target.center + offset
        var z = SIMD2<Double>(repeating: 0)
        for i in 0..<maxIter {
            if z.x * z.x + z.y * z.y > 256 { return i }
            let x = z.x * z.x - z.y * z.y + c.x
            let y = 2 * z.x * z.y + c.y
            z = SIMD2(x, y)
        }
        return nil
    }
}

struct JuliaFormula: FractalFormula {
    let id = "julia"
    let displayName = "Julia"
    let shaderID = FormulaShaderID.julia
    let tuning = FormulaTuning()
    let targets: [ZoomTarget] = [
        ZoomTarget(name: "Dragon", center: SIMD2(-0.15, 0.15), minScale: 2.0e-10, parameter: SIMD2(-0.8, 0.156)),
        ZoomTarget(name: "Douady Rabbit", center: SIMD2(-0.2, 0.55), minScale: 2.0e-10, parameter: SIMD2(-0.123, 0.745)),
        ZoomTarget(name: "Spiral Arms", center: SIMD2(0.0, 0.0), minScale: 1.5e-10, parameter: SIMD2(-0.7269, 0.1889)),
        ZoomTarget(name: "Filament Nest", center: SIMD2(0.35, 0.35), minScale: 2.0e-10, parameter: SIMD2(-0.4, 0.6)),
        ZoomTarget(name: "Near Circle", center: SIMD2(0.0, 0.0), minScale: 1.5e-10, parameter: SIMD2(0.285, 0.01)),
        ZoomTarget(name: "Galaxy Swirl", center: SIMD2(0.0, 0.0), minScale: 1.5e-10, parameter: SIMD2(-0.7, 0.270_15)),
        ZoomTarget(name: "Siegel Disk", center: SIMD2(0.0, 0.0), minScale: 1.5e-10, parameter: SIMD2(-0.390_54, 0.586_79)),
        ZoomTarget(name: "Basilica", center: SIMD2(0.0, 0.0), minScale: 2.0e-10, parameter: SIMD2(-1.0, 0.0)),
        ZoomTarget(name: "Dendrite", center: SIMD2(0.0, 0.0), minScale: 2.0e-10, parameter: SIMD2(0.0, 1.0)),
        ZoomTarget(name: "San Marco", center: SIMD2(0.0, 0.0), minScale: 2.0e-10, parameter: SIMD2(-0.75, 0.0)),
        ZoomTarget(name: "Airplane", center: SIMD2(0.0, 0.0), minScale: 1.5e-10, parameter: SIMD2(-1.755, 0.0)),
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

    func escapeIteration(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Int? {
        var z = target.center + offset
        let c = target.parameter
        for i in 0..<maxIter {
            if z.x * z.x + z.y * z.y > 256 { return i }
            let x = z.x * z.x - z.y * z.y + c.x
            let y = 2 * z.x * z.y + c.y
            z = SIMD2(x, y)
        }
        return nil
    }
}

struct BurningShipFormula: FractalFormula {
    let id = "burningShip"
    let displayName = "Burning Ship"
    let shaderID = FormulaShaderID.burningShip
    let tuning = FormulaTuning()
    let targets: [ZoomTarget] = [
        ZoomTarget(name: "Main Hull", center: SIMD2(-1.76, 0.03), minScale: 1.5e-10),
        ZoomTarget(name: "Bow Detail", center: SIMD2(-1.768, 0.0055), minScale: 1.0e-10),
        ZoomTarget(name: "Western Ship", center: SIMD2(-1.861, 0.005), minScale: 2.0e-10),
        ZoomTarget(name: "Mid Fleet", center: SIMD2(-1.627, 0.015), minScale: 2.0e-10),
        ZoomTarget(name: "Upper Deck", center: SIMD2(-1.775, 0.01), minScale: 1.5e-10),
        ZoomTarget(name: "Bow Jets", center: SIMD2(-1.749_7, -0.031_62), minScale: 1.5e-10),
        ZoomTarget(name: "Main Antenna", center: SIMD2(-1.756, -0.028), minScale: 1.5e-10),
        ZoomTarget(name: "Mini Ship", center: SIMD2(-1.762, -0.028), minScale: 1.0e-10),
        ZoomTarget(name: "Ship −1.57", center: SIMD2(-1.565, -0.017), minScale: 2.0e-10),
        ZoomTarget(name: "Far Ship −1.94", center: SIMD2(-1.936_5, -0.003_75), minScale: 1.5e-10),
        ZoomTarget(name: "Deep Antenna", center: SIMD2(-1.778_7, -0.016_221_6), minScale: 1.0e-10),
        ZoomTarget(name: "Mast", center: SIMD2(-1.773_75, -0.058_25), minScale: 2.0e-10),
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

    func escapeIteration(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Int? {
        let c = target.center + offset
        var z = SIMD2<Double>(repeating: 0)
        for i in 0..<maxIter {
            if z.x * z.x + z.y * z.y > 256 { return i }
            let ax = abs(z.x)
            let ay = abs(z.y)
            z = SIMD2(ax * ax - ay * ay + c.x, 2 * ax * ay + c.y)
        }
        return nil
    }
}

/// Mandelbar: \(z \mapsto \overline{z}^2 + c\).
struct TricornFormula: FractalFormula {
    let id = "tricorn"
    let displayName = "Tricorn"
    let shaderID = FormulaShaderID.tricorn
    let tuning = FormulaTuning()
    let targets: [ZoomTarget] = [
        ZoomTarget(name: "Main Body", center: SIMD2(-0.5, 0.0), minScale: 2.0e-10),
        ZoomTarget(name: "Upper Bulb", center: SIMD2(-0.15, 0.85), minScale: 2.0e-10),
        ZoomTarget(name: "Lower Bulb", center: SIMD2(-0.15, -0.85), minScale: 2.0e-10),
        ZoomTarget(name: "West Tip", center: SIMD2(-1.75, 0.0), minScale: 1.5e-10),
        ZoomTarget(name: "Filament Nest", center: SIMD2(-0.2, 0.65), minScale: 2.0e-10),
        ZoomTarget(name: "Triple Spiral", center: SIMD2(0.0, 0.75), minScale: 1.5e-10),
        ZoomTarget(name: "Mirror Seahorse", center: SIMD2(-0.75, 0.12), minScale: 1.5e-10),
        ZoomTarget(name: "Edge Spire", center: SIMD2(-0.05, 1.0), minScale: 2.0e-10),
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
            // conj(z)^2 + c
            let x = z.x * z.x - z.y * z.y + c.x
            let y = -2 * z.x * z.y + c.y
            z = SIMD2(x, y)
        }
        return count
    }

    func escapeIteration(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Int? {
        let c = target.center + offset
        var z = SIMD2<Double>(repeating: 0)
        for i in 0..<maxIter {
            if z.x * z.x + z.y * z.y > 256 { return i }
            let x = z.x * z.x - z.y * z.y + c.x
            let y = -2 * z.x * z.y + c.y
            z = SIMD2(x, y)
        }
        return nil
    }
}

/// Burning Ship with fixed Julia parameter `c`; pixel is the \(z\)-offset.
struct BurningShipJuliaFormula: FractalFormula {
    let id = "burningShipJulia"
    let displayName = "Ship Julia"
    let shaderID = FormulaShaderID.burningShipJulia
    let tuning = FormulaTuning(overviewScale: 1.8)
    let targets: [ZoomTarget] = [
        ZoomTarget(name: "Classic Ship c", center: SIMD2(0.0, 0.0), minScale: 2.0e-10, parameter: SIMD2(-1.76, 0.03)),
        ZoomTarget(name: "Bow Jets c", center: SIMD2(0.0, 0.0), minScale: 1.5e-10, parameter: SIMD2(-1.749_7, -0.031_62)),
        ZoomTarget(name: "Antenna c", center: SIMD2(0.15, 0.1), minScale: 1.5e-10, parameter: SIMD2(-1.756, -0.028)),
        ZoomTarget(name: "Near Hull", center: SIMD2(-0.2, 0.05), minScale: 2.0e-10, parameter: SIMD2(-1.7, 0.0)),
        ZoomTarget(name: "Mast Region", center: SIMD2(0.0, -0.1), minScale: 2.0e-10, parameter: SIMD2(-1.773_75, -0.058_25)),
        ZoomTarget(name: "Deep Antenna c", center: SIMD2(0.05, 0.0), minScale: 1.0e-10, parameter: SIMD2(-1.778_7, -0.016_221_6)),
        ZoomTarget(name: "Far West c", center: SIMD2(0.0, 0.0), minScale: 1.5e-10, parameter: SIMD2(-1.86, 0.005)),
        ZoomTarget(name: "Mid Fleet c", center: SIMD2(0.1, -0.05), minScale: 2.0e-10, parameter: SIMD2(-1.627, 0.015)),
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
            let ax = abs(z.x)
            let ay = abs(z.y)
            z = SIMD2(ax * ax - ay * ay + c.x, 2 * ax * ay + c.y)
        }
        return count
    }

    func escapeIteration(offset: SIMD2<Double>, target: ZoomTarget, maxIter: Int) -> Int? {
        var z = target.center + offset
        let c = target.parameter
        for i in 0..<maxIter {
            if z.x * z.x + z.y * z.y > 256 { return i }
            let ax = abs(z.x)
            let ay = abs(z.y)
            z = SIMD2(ax * ax - ay * ay + c.x, 2 * ax * ay + c.y)
        }
        return nil
    }
}
