import Testing
import simd

@testable import Ganzfeld

/// The sRGB → linear conversion `AppModel` applies before any compositing
/// maths, checked against values computed independently from the IEC
/// 61966-2-1 definition rather than against the app's own constants.
@MainActor
@Suite("sRGB to linear conversion")
struct SRGBConversionTests {

    /// Solid at full intensity emits the linear colour unchanged, so it is the
    /// cleanest window onto the transfer function.
    private func linearized(_ channel: Double) -> SIMD3<Double> {
        let model = AppModel()
        let params = model.configure(
            mode: .solid,
            color: SIMD3(channel, channel, channel),
            intensity: 1
        )
        return SIMD3(Double(params.rgba.x), Double(params.rgba.y), Double(params.rgba.z))
    }

    @Test(
        "known sRGB values map to the documented linear values",
        arguments: zip(
            [0.0, 0.04045, 0.2, 0.25, 0.5, 1.0],
            [
                0.0,
                0.003_130_804_953_560_371,
                0.033_104_766_570_885_055,
                0.050_876_088_171_556_79,
                0.214_041_140_482_232_55,
                1.0,
            ]
        )
    )
    func knownValues(input: Double, expected: Double) {
        let linear = linearized(input)
        #expect(isClose(linear.x, expected, tolerance: 1e-6))
        #expect(isClose(linear, SIMD3(repeating: expected), tolerance: 1e-6))
    }

    @Test("the curve is continuous across the 0.04045 knee")
    func continuousAtKnee() {
        let below = linearized(0.04045 - 1e-4).x
        let above = linearized(0.04045 + 1e-4).x
        #expect(isClose(below, above, tolerance: 1e-4))
    }

    @Test("the curve is strictly increasing")
    func monotonic() {
        var previous = -1.0
        for step in 0...100 {
            let value = linearized(Double(step) / 100).x
            #expect(value > previous)
            previous = value
        }
    }

    @Test("endpoints are exact so full white and full black are not shifted")
    func endpointsAreExact() {
        #expect(linearized(0).x == 0)
        // Not bit-exact: 1.0 travels through (1 + 0.055) / 1.055 in Float.
        #expect(isClose(linearized(1).x, 1, tolerance: 1e-6))
    }

    @Test("mid-grey darkens, as a gamma curve must")
    func midGreyIsDarkened() {
        // A naive implementation that forgot the conversion would emit 0.5.
        #expect(linearized(0.5).x < 0.25)
    }

    @Test("channels are converted independently, not coupled")
    func channelsAreIndependent() {
        let model = AppModel()
        let params = model.configure(
            mode: .solid,
            color: SIMD3(1, 0.5, 0),
            intensity: 1
        )
        #expect(isClose(Double(params.rgba.x), 1, tolerance: 1e-6))
        #expect(isClose(Double(params.rgba.y), Reference.srgbToLinear(0.5), tolerance: 1e-6))
        #expect(Double(params.rgba.z) == 0)
    }
}

/// Per-mode premultiplied output, matching the table in the README.
@MainActor
@Suite("Premultiplied layer output per mode")
struct LayerOutputTests {

    @Test("solid emits (k·C, k)", arguments: sampleColors, sampleIntensities)
    func solid(color: SIMD3<Double>, intensity: Double) {
        let params = AppModel().configure(mode: .solid, color: color, intensity: intensity)
        let c = color.mapped(Reference.srgbToLinear)
        #expect(isClose(params.rgba, rgba(c * intensity, intensity)))
    }

    @Test("additive emits (k·C, 0)", arguments: sampleColors, sampleIntensities)
    func additive(color: SIMD3<Double>, intensity: Double) {
        let params = AppModel().configure(mode: .additive, color: color, intensity: intensity)
        let c = color.mapped(Reference.srgbToLinear)
        #expect(isClose(params.rgba, rgba(c * intensity, 0)))
        #expect(params.rgba.w == 0, "additive must never attenuate passthrough")
    }

    @Test("subtractive emits (0, k·Y(C))", arguments: sampleColors, sampleIntensities)
    func subtractive(color: SIMD3<Double>, intensity: Double) {
        let params = AppModel().configure(mode: .subtractive, color: color, intensity: intensity)
        let luminance = Reference.luminance(color.mapped(Reference.srgbToLinear))
        #expect(isClose(params.rgba, rgba(SIMD3(repeating: 0), intensity * luminance)))
        #expect(params.rgba.rgb == SIMD3<Float>(repeating: 0), "subtractive must add no light")
    }

    @Test("subtractive with a black filter removes nothing", arguments: sampleIntensities)
    func subtractiveBlackIsInert(intensity: Double) {
        let params = AppModel().configure(
            mode: .subtractive,
            color: SIMD3(0, 0, 0),
            intensity: intensity
        )
        #expect(params.rgba == SIMD4<Float>(0, 0, 0, 0))
    }

    @Test("subtractive with a white filter at full intensity removes everything")
    func subtractiveWhiteIsOpaque() {
        let params = AppModel().configure(
            mode: .subtractive,
            color: SIMD3(1, 1, 1),
            intensity: 1
        )
        #expect(isClose(Double(params.rgba.w), 1, tolerance: 1e-6))
    }

    @Test("subtractive weights the primaries by Rec. 709 luminance")
    func subtractiveUsesRec709Weights() {
        func alpha(_ color: SIMD3<Double>) -> Double {
            Double(
                AppModel().configure(mode: .subtractive, color: color, intensity: 1).rgba.w
            )
        }
        #expect(isClose(alpha(SIMD3(1, 0, 0)), 0.2126, tolerance: 1e-6))
        #expect(isClose(alpha(SIMD3(0, 1, 0)), 0.7152, tolerance: 1e-6))
        #expect(isClose(alpha(SIMD3(0, 0, 1)), 0.0722, tolerance: 1e-6))
        // Green must dim more than red, which must dim more than blue.
        #expect(alpha(SIMD3(0, 1, 0)) > alpha(SIMD3(1, 0, 0)))
        #expect(alpha(SIMD3(1, 0, 0)) > alpha(SIMD3(0, 0, 1)))
    }

    @Test(
        "zero intensity is a no-op in every mode",
        arguments: OverlayMode.allCases, sampleColors
    )
    func zeroIntensityIsInert(mode: OverlayMode, color: SIMD3<Double>) {
        let params = AppModel().configure(mode: mode, color: color, intensity: 0)
        #expect(params.rgba == SIMD4<Float>(0, 0, 0, 0))
    }

    @Test("solid at full intensity is the opaque colour itself", arguments: sampleColors)
    func solidAtFullIntensity(color: SIMD3<Double>) {
        let params = AppModel().configure(mode: .solid, color: color, intensity: 1)
        #expect(isClose(params.rgba, rgba(color.mapped(Reference.srgbToLinear), 1)))
    }
}

extension SIMD3 where Scalar == Double {
    func mapped(_ transform: (Double) -> Double) -> SIMD3<Double> {
        SIMD3(transform(x), transform(y), transform(z))
    }
}
