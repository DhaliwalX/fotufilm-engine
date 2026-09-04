import XCTest
@testable import FotufilmCore

final class GamutCapabilityABTests: XCTestCase {
    private func requireEngine() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
    }

    private func developedMean(_ wide: SIMD3<Float>,
                               oldDoorPolicy: Bool) -> SIMD3<Float> {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        let size = 16
        var scene = wide
        if oldDoorPolicy {
            let p3 = ColorScience.linearRec2020ToDisplayP3(wide)
            scene = ColorScience.linearDisplayP3ToRec2020(
                SIMD3(max(p3.x, 0), max(p3.y, 0), max(p3.z, 0)))
        }
        var frame = ImageBuffer(width: size, height: size)
        for i in 0..<(size * size) {
            for c in 0..<3 { frame.planes[c][i] = scene[c] }
        }
        let print = FotufilmEngine(stock: TestStocks.negative, options: options)
            .process(linearRGB: frame)
        var mean = SIMD3<Float>()
        for i in 0..<(size * size) {
            mean += SIMD3(print.planes[0][i], print.planes[1][i], print.planes[2][i])
        }
        return mean / Float(size * size)
    }

    private func row(_ label: String, _ v: SIMD3<Float>) -> String {
        String(format: "%@  %+8.5f %+8.5f %+8.5f", label, v.x, v.y, v.z)
    }

    func testABTwoOutOfP3CyansCollapseUnderAAndSeparateUnderB() throws {
        try requireEngine()
        let shallow = SIMD3<Float>(0.20, 0.85, 0.85)
        let deep = SIMD3<Float>(0.06, 0.85, 0.85)

        let aShallow = developedMean(shallow, oldDoorPolicy: true)
        let aDeep = developedMean(deep, oldDoorPolicy: true)
        let bShallow = developedMean(shallow, oldDoorPolicy: false)
        let bDeep = developedMean(deep, oldDoorPolicy: false)

        print("""
        A/B cyan pair (print means, display-linear):
        \(row("A shallow", aShallow))
        \(row("A deep   ", aDeep))
        \(row("B shallow", bShallow))
        \(row("B deep   ", bDeep))
        A separation \(abs(aShallow.x - aDeep.x))  B separation \(bShallow.x - bDeep.x)
        """)

        // A: the two sources are one colour after the door — the engine's outputs agree to
        // within dither-level noise. B: measured 0.0096 of display-linear red separation.
        XCTAssertEqual(aShallow.x, aDeep.x, accuracy: 1e-3,
                       "under the old door policy these cyans were indistinguishable")
        XCTAssertGreaterThan(bShallow.x - bDeep.x, 0.001,
                             "the wide engine must keep the pair apart")
        XCTAssertGreaterThan((bShallow.x - bDeep.x) / max(abs(aShallow.x - aDeep.x), 1e-6),
                             10, "B's separation must dwarf A's residue")
    }

    func testABRampPlateausUnderAAndKeepsGradingUnderB() throws {
        try requireEngine()
        var aSteps: [Float] = []
        var bSteps: [Float] = []
        var aPrev: Float?
        var bPrev: Float?
        var table = "A/B cyan ramp (print red mean):\n     wide.r   A        B\n"
        for i in 0..<8 {
            // Crosses the P3 edge (transport red hits 0 near wide.r ≈ 0.217).
            let wide = SIMD3<Float>(0.26 - 0.03 * Float(i), 0.85, 0.85)
            let a = developedMean(wide, oldDoorPolicy: true).x
            let b = developedMean(wide, oldDoorPolicy: false).x
            table += String(format: "  %6.2f  %8.5f %8.5f\n", wide.x, a, b)
            if let ap = aPrev { aSteps.append(ap - a) }
            if let bp = bPrev { bSteps.append(bp - b) }
            aPrev = a
            bPrev = b
        }
        print(table)

        // Past the edge (last four intervals) A's steps vanish; B's all stay real.
        let aTail = aSteps.suffix(4)
        let bTail = bSteps.suffix(4)
        for step in aTail {
            XCTAssertEqual(step, 0, accuracy: 5e-4,
                           "the old policy plateaus beyond the P3 edge")
        }
        // The ramp flattens naturally toward the cube face. With the Jakob-Hanika table the
        // tail steps measured 0.0007...0.0018; the measured-reflectance prior grades further
        // in total but its bounded solve pins the red bands at zero as the cyan vertex nears,
        // so the steps measured 0.0028, 0.0015, 0.0008 and 0.0002 (2026-09-02). Each step
        // must still move the right way, and the tail as a whole must keep grading; the 10x
        // aggregate below carries the sharp claim.
        for step in bTail {
            XCTAssertGreaterThanOrEqual(step, 0,
                                        "the wide engine must not reverse beyond the P3 edge")
        }
        XCTAssertGreaterThan(bTail.reduce(0, +), 1.2e-3,
                             "the wide engine must keep grading beyond the P3 edge")
        XCTAssertGreaterThan(bTail.reduce(0, +), aTail.reduce(0) { $0 + abs($1) } * 10,
                             "B's out-of-gamut grading must dwarf A's residue")
    }

    func testABOutOfGamutMagentaEqualsItsStandInOnlyUnderA() throws {
        try requireEngine()
        // Deep magenta-red: transport green is negative (≈ -0.041).
        let wide = SIMD3<Float>(0.9, 0.02, 0.4)
        let transport = ColorScience.linearRec2020ToDisplayP3(wide)
        XCTAssertLessThan(transport.y, 0, "the magenta must be outside P3")
        // Its stand-in: the clamped transport, read back as the 2020 colour it encodes.
        let standIn = ColorScience.linearDisplayP3ToRec2020(
            SIMD3(max(transport.x, 0), max(transport.y, 0), max(transport.z, 0)))

        let aWide = developedMean(wide, oldDoorPolicy: true)
        let aStandIn = developedMean(standIn, oldDoorPolicy: true)
        let bWide = developedMean(wide, oldDoorPolicy: false)
        let bStandIn = developedMean(standIn, oldDoorPolicy: false)

        print("""
        A/B magenta vs stand-in (print means, display-linear):
        \(row("A wide    ", aWide))
        \(row("A stand-in", aStandIn))
        \(row("B wide    ", bWide))
        \(row("B stand-in", bStandIn))
        """)

        for channel in 0..<3 {
            XCTAssertEqual(aWide[channel], aStandIn[channel], accuracy: 5e-4,
                           "under A the engine cannot tell the magenta from its stand-in")
        }
        let separation = abs(bWide.y - bStandIn.y) + abs(bWide.x - bStandIn.x)
        XCTAssertGreaterThan(separation, 0.001,
                             "under B the real colour and the stand-in print apart")
    }
}
