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
        [(Defaults.allId, "Alle")] + all.map { ($0.id, $0.displayName) }
    }

    static func named(_ id: String) -> FractalFormula {
        all.first { $0.id == id } ?? MandelbrotFormula()
    }

    static func random(avoiding: String? = nil) -> FractalFormula {
        guard all.count > 1, let avoiding else {
            return all.randomElement() ?? MandelbrotFormula()
        }
        let pool = all.filter { $0.id != avoiding }
        return pool.randomElement() ?? all.randomElement() ?? MandelbrotFormula()
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
    // Centers verified against the stale-probe: must stay on set boundary
    // (mixed interior/escape), not land in solid interior or uniform wash.
    let targets: [ZoomTarget] = [
        ZoomTarget(name: "Seahorse Valley", center: SIMD2(-0.743_643_887_037_151, 0.131_825_904_205_330), minScale: 1.0e-10),
        ZoomTarget(name: "Seahorse Mouth", center: SIMD2(-0.711_864_0411, 0.226_413_8912), minScale: 2.0e-10),
        ZoomTarget(name: "Mutated Seahorse", center: SIMD2(-0.648_942_7095, 0.366_819_8389), minScale: 2.0e-10),
        ZoomTarget(name: "Northern Spire", center: SIMD2(-0.160_701_35, 1.037_566_5), minScale: 2.0e-10),
        ZoomTarget(name: "West Filament", center: SIMD2(-1.250_66, 0.020_12), minScale: 1.5e-10),
        ZoomTarget(name: "Double Spiral", center: SIMD2(-0.765_750_9872, 0.096_388_1478), minScale: 1.0e-10),
        ZoomTarget(name: "Upper Bulb Edge", center: SIMD2(-0.218_830_4638, 0.726_373_1482), minScale: 2.0e-10),
        ZoomTarget(name: "Scepter Tip", center: SIMD2(-1.768_778_8, -0.001_738_9), minScale: 1.5e-10),
        ZoomTarget(name: "Elephant Valley", center: SIMD2(0.328_524_4877, 0.057_326_5652), minScale: 2.0e-10),
        ZoomTarget(name: "Elephant Cusp", center: SIMD2(0.258_725_7364, -0.001_637_6031), minScale: 2.0e-10),
        ZoomTarget(name: "Feigenbaum", center: SIMD2(-1.370_427_8092, -0.008_415_9496), minScale: 1.5e-10),
        ZoomTarget(name: "Period-3 Bulb", center: SIMD2(-0.140_611_0161, 0.858_464_8698), minScale: 2.0e-10),
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
    // Zoom `center` must sit on the Julia *boundary* (filaments). Many classic
    // Julia `c` values look great at overview with center (0,0), but (0,0) is
    // interior / featureless once scale drops — the stale-probe correctly aborts.
    let targets: [ZoomTarget] = [
        ZoomTarget(name: "Dragon", center: SIMD2(0.286_365, 0.170_940), minScale: 1.0e-10, parameter: SIMD2(-0.8, 0.156)),
        ZoomTarget(name: "Douady Rabbit", center: SIMD2(0.369_596, 0.226_666), minScale: 1.0e-5, parameter: SIMD2(-0.123, 0.745)),
        ZoomTarget(name: "Spiral Arms", center: SIMD2(-0.227_946, -0.113_322), minScale: 1.5e-10, parameter: SIMD2(-0.7269, 0.1889)),
        ZoomTarget(name: "Filament Nest", center: SIMD2(-0.273_268, 0.278_440), minScale: 2.0e-10, parameter: SIMD2(-0.4, 0.6)),
        ZoomTarget(name: "Galaxy Swirl", center: SIMD2(-0.544_754, -0.231_564), minScale: 1.5e-10, parameter: SIMD2(-0.7, 0.270_15)),
        // Dendrite/Airplane (thin sets, center 0) never survive deep zoom — replaced.
        ZoomTarget(name: "Snowflake", center: SIMD2(-0.600_150, -0.229_852), minScale: 1.5e-10, parameter: SIMD2(-0.745_43, 0.113_01)),
        ZoomTarget(name: "Classic Spiral", center: SIMD2(-0.448_627, -0.480_322), minScale: 1.5e-10, parameter: SIMD2(-0.835, -0.2321)),
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
        ZoomTarget(name: "Main Hull", center: SIMD2(-1.785_912_7612, -0.008_259_0232), minScale: 1.5e-10),
        ZoomTarget(name: "Bow Detail", center: SIMD2(-1.775_144_8613, -0.023_015_6240), minScale: 1.0e-10),
        ZoomTarget(name: "Western Ship", center: SIMD2(-1.771_228_2519, -0.022_807_0054), minScale: 2.0e-10),
        ZoomTarget(name: "Mid Fleet", center: SIMD2(-1.635_609_8577, -0.005_969_0731), minScale: 2.0e-10),
        ZoomTarget(name: "Upper Deck", center: SIMD2(-1.755_133_1857, -0.023_507_2807), minScale: 1.5e-10),
        ZoomTarget(name: "Bow Jets", center: SIMD2(-1.749_7, -0.031_62), minScale: 1.5e-10),
        ZoomTarget(name: "Main Antenna", center: SIMD2(-1.780_023_4576, -0.019_393_8934), minScale: 1.5e-10),
        ZoomTarget(name: "Mini Ship", center: SIMD2(-1.762, -0.028), minScale: 1.0e-10),
        ZoomTarget(name: "Ship −1.57", center: SIMD2(-1.498_438_9073, -0.052_157_3403), minScale: 2.0e-10),
        ZoomTarget(name: "Far Ship −1.94", center: SIMD2(-1.764_009_3067, -0.024_063_5550), minScale: 1.5e-10),
        ZoomTarget(name: "Deep Antenna", center: SIMD2(-1.778_7, -0.016_221_6), minScale: 1.0e-10),
        ZoomTarget(name: "Mast", center: SIMD2(-1.749_496_7219, 0.003_791_2354), minScale: 2.0e-10),
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
        ZoomTarget(name: "Main Body", center: SIMD2(-0.733_778_0518, 0.078_903_8215), minScale: 2.0e-10),
        ZoomTarget(name: "Upper Bulb", center: SIMD2(0.300_065_7581, 0.669_711_1708), minScale: 2.0e-10),
        ZoomTarget(name: "Lower Bulb", center: SIMD2(0.295_531_4105, -0.681_193_6090), minScale: 2.0e-10),
        ZoomTarget(name: "West Tip", center: SIMD2(-1.75, 0.0), minScale: 1.5e-10),
        ZoomTarget(name: "Filament Nest", center: SIMD2(0.289_960_8786, 0.661_810_4241), minScale: 2.0e-10),
        ZoomTarget(name: "Triple Spiral", center: SIMD2(0.235_218_6269, 0.527_987_4027), minScale: 1.5e-10),
        ZoomTarget(name: "Mirror Seahorse", center: SIMD2(-0.972_452_2760, 0.103_755_1066), minScale: 1.5e-10),
        ZoomTarget(name: "Edge Spire", center: SIMD2(0.389_293_0354, 0.888_903_9520), minScale: 2.0e-10),
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
    // Only `c` values that keep a deep boundary under the zoom center.
    let targets: [ZoomTarget] = [
        ZoomTarget(name: "Deep Antenna c", center: SIMD2(0.252_281_2806, 0.052_609_5379), minScale: 1.0e-10, parameter: SIMD2(-1.778_7, -0.016_221_6)),
        ZoomTarget(name: "Bow Jets c", center: SIMD2(-0.231_214_4884, -0.041_184_0413), minScale: 1.5e-10, parameter: SIMD2(-1.749_7, -0.031_62)),
        ZoomTarget(name: "Antenna c", center: SIMD2(0.606_270_9453, 0.069_940_9566), minScale: 1.5e-10, parameter: SIMD2(-1.756, -0.028)),
        ZoomTarget(name: "Mast Region", center: SIMD2(-0.104_419_9790, -0.196_740_1539), minScale: 2.0e-10, parameter: SIMD2(-1.773_75, -0.058_25)),
        ZoomTarget(name: "Hull Jets", center: SIMD2(-0.078_067_1636, -0.190_102_2830), minScale: 1.5e-10, parameter: SIMD2(-1.75, -0.03)),
        ZoomTarget(name: "West Mast c", center: SIMD2(0.979_182_1416, 0.051_655_7276), minScale: 1.5e-10, parameter: SIMD2(-1.731_790, -0.055_991)),
        ZoomTarget(name: "Mid Antenna c", center: SIMD2(0.870_738_9550, 0.007_225_6337), minScale: 1.5e-10, parameter: SIMD2(-1.638_560, -0.021_772)),
        ZoomTarget(name: "Fleet Tip c", center: SIMD2(0.253_039_0737, -0.078_242_2721), minScale: 2.0e-10, parameter: SIMD2(-1.570_598, -0.050_534)),
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
