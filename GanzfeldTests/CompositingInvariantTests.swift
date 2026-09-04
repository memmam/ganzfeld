import Testing
import simd

@testable import Ganzfeld

/// What the treated eye actually receives, once the system compositor has
/// blended the layer over passthrough. These are the promises the README makes
/// to someone running a perceptual experiment, so they are asserted against
/// every passthrough radiance rather than a single convenient one.
@MainActor
@Suite("Compositing invariants")
struct CompositingInvariantTests {

    private func layer(
        mode: OverlayMode,
        color: SIMD3<Double>,
        intensity: Double
    ) -> SIMD4<Double> {
        AppModel().configure(mode: mode, color: color, intensity: intensity).rgba.doubles
    }

    @Test(
        "zero intensity leaves passthrough untouched in every mode",
        arguments: OverlayMode.allCases, sampleColors
    )
    func zeroIntensityIsIdentity(mode: OverlayMode, color: SIMD3<Double>) {
        let l = layer(mode: mode, color: color, intensity: 0)
        for passthrough in samplePassthrough {
            #expect(Reference.composite(layer: l, over: passthrough) == passthrough)
        }
    }

    @Test("additive only ever adds light", arguments: sampleColors, sampleIntensities)
    func additiveNeverDarkens(color: SIMD3<Double>, intensity: Double) {
        let l = layer(mode: .additive, color: color, intensity: intensity)
        for passthrough in samplePassthrough {
            let result = Reference.composite(layer: l, over: passthrough)
            #expect(result.x >= passthrough.x)
            #expect(result.y >= passthrough.y)
            #expect(result.z >= passthrough.z)
        }
    }

    @Test("additive adds exactly k·C", arguments: sampleColors, sampleIntensities)
    func additiveIsExact(color: SIMD3<Double>, intensity: Double) {
        let l = layer(mode: .additive, color: color, intensity: intensity)
        let expectedDelta = color.mapped(Reference.srgbToLinear) * intensity
        for passthrough in samplePassthrough {
            let result = Reference.composite(layer: l, over: passthrough)
            #expect(isClose(result - passthrough, expectedDelta))
        }
    }

    /// The bug this whole mode was rewritten to fix: an earlier version could
    /// come out *brighter* than the passthrough behind it.
    @Test("subtractive never brightens", arguments: sampleColors, sampleIntensities)
    func subtractiveNeverBrightens(color: SIMD3<Double>, intensity: Double) {
        let l = layer(mode: .subtractive, color: color, intensity: intensity)
        for passthrough in samplePassthrough {
            let result = Reference.composite(layer: l, over: passthrough)
            #expect(result.x <= passthrough.x + 1e-6)
            #expect(result.y <= passthrough.y + 1e-6)
            #expect(result.z <= passthrough.z + 1e-6)
        }
    }

    @Test("subtractive attenuates every channel by the same factor",
          arguments: sampleColors, sampleIntensities)
    func subtractiveIsNeutral(color: SIMD3<Double>, intensity: Double) {
        let l = layer(mode: .subtractive, color: color, intensity: intensity)
        let passthrough = SIMD3<Double>(0.8, 0.5, 0.2)
        let result = Reference.composite(layer: l, over: passthrough)
        let factors = [
            result.x / passthrough.x,
            result.y / passthrough.y,
            result.z / passthrough.z,
        ]
        #expect(isClose(factors[0], factors[1]))
        #expect(isClose(factors[1], factors[2]))
        // Neutral attenuation means the hue of the passthrough is preserved:
        // a "red filter" cannot tint the world red, only dim it.
        #expect(factors[0] <= 1 + 1e-9)
    }

    @Test("solid at full intensity replaces passthrough entirely",
          arguments: sampleColors)
    func solidIsOpaqueAtFullIntensity(color: SIMD3<Double>) {
        let l = layer(mode: .solid, color: color, intensity: 1)
        let expected = color.mapped(Reference.srgbToLinear)
        for passthrough in samplePassthrough {
            #expect(isClose(Reference.composite(layer: l, over: passthrough), expected))
        }
    }

    @Test("solid cross-fades linearly between passthrough and the colour",
          arguments: sampleColors, sampleIntensities)
    func solidCrossFades(color: SIMD3<Double>, intensity: Double) {
        let l = layer(mode: .solid, color: color, intensity: intensity)
        let c = color.mapped(Reference.srgbToLinear)
        for passthrough in samplePassthrough {
            let expected = c * intensity + passthrough * (1 - intensity)
            #expect(isClose(Reference.composite(layer: l, over: passthrough), expected))
        }
    }

    @Test("layer alpha always stays in 0...1",
          arguments: OverlayMode.allCases, sampleColors)
    func alphaIsInRange(mode: OverlayMode, color: SIMD3<Double>) {
        for intensity in sampleIntensities {
            let alpha = layer(mode: mode, color: color, intensity: intensity).w
            #expect(alpha >= 0)
            #expect(alpha <= 1)
        }
    }

    /// Solid and subtractive both describe surfaces that occlude; their
    /// premultiplied colour must therefore never exceed their alpha. Additive
    /// is deliberately exempt — it emits light with zero coverage.
    @Test("occluding modes emit valid premultiplied colour",
          arguments: [OverlayMode.solid, .subtractive], sampleColors)
    func premultipliedColorIsValid(mode: OverlayMode, color: SIMD3<Double>) {
        for intensity in sampleIntensities {
            let l = layer(mode: mode, color: color, intensity: intensity)
            #expect(l.x <= l.w + 1e-6)
            #expect(l.y <= l.w + 1e-6)
            #expect(l.z <= l.w + 1e-6)
        }
    }

    @Test("no mode emits a channel outside 0...1",
          arguments: OverlayMode.allCases, sampleColors)
    func channelsAreInRange(mode: OverlayMode, color: SIMD3<Double>) {
        for intensity in sampleIntensities {
            let l = layer(mode: mode, color: color, intensity: intensity)
            for channel in [l.x, l.y, l.z, l.w] {
                #expect(channel >= 0)
                #expect(channel <= 1)
            }
        }
    }

    /// Raising the slider must monotonically strengthen the effect in every
    /// mode — no mode may peak in the middle of its range.
    @Test("effect strength is monotone in intensity", arguments: OverlayMode.allCases)
    func strengthIsMonotone(mode: OverlayMode) {
        let color = SIMD3<Double>(0.9, 0.4, 0.1)
        let passthrough = SIMD3<Double>(0.5, 0.5, 0.5)
        var previousDistance = -1.0
        for step in 0...50 {
            let intensity = Double(step) / 50
            let l = layer(mode: mode, color: color, intensity: intensity)
            let result = Reference.composite(layer: l, over: passthrough)
            let distance = simd_length(result - passthrough)
            #expect(distance >= previousDistance - 1e-9)
            previousDistance = distance
        }
    }
}
