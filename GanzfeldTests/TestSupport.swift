import Foundation
import simd

@testable import Ganzfeld

/// Independent reference implementations of the colour pipeline, kept separate
/// from `AppModel`'s so a typo in either side shows up as a failing test rather
/// than cancelling out.
enum Reference {
    /// IEC 61966-2-1 sRGB electro-optical transfer function.
    static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Inverse of `srgbToLinear` — what an `_srgb` render target applies when a
    /// linear value is written to it.
    static func linearToSRGB(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// Rec. 709 relative luminance of a linear-light colour.
    static func luminance(_ c: SIMD3<Double>) -> Double {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    /// The system compositor's premultiplied source-over blend, as documented
    /// in the README: `result = layer.rgb + (1 - layer.a) * passthrough`.
    static func composite(layer: SIMD4<Double>, over passthrough: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(layer.x, layer.y, layer.z) + (1 - layer.w) * passthrough
    }
}

extension SIMD4 where Scalar == Float {
    var rgb: SIMD3<Float> { SIMD3<Float>(x, y, z) }
    // Inside this extension a bare `SIMD4` would mean `SIMD4<Float>`.
    var doubles: SIMD4<Double> { SIMD4<Double>(Double(x), Double(y), Double(z), Double(w)) }
}

/// Colours (as sRGB slider values) that between them exercise the achromatic
/// ends, each primary, the sRGB curve's linear toe, and an off-axis mixture.
let sampleColors: [SIMD3<Double>] = [
    SIMD3(0, 0, 0),
    SIMD3(1, 1, 1),
    SIMD3(1, 0, 0),
    SIMD3(0, 1, 0),
    SIMD3(0, 0, 1),
    SIMD3(0.5, 0.5, 0.5),
    SIMD3(0.02, 0.03, 0.04),
    SIMD3(0.9, 0.4, 0.1),
]

/// Intensities spanning both endpoints and the interior.
let sampleIntensities: [Double] = [0, 0.01, 0.25, 0.5, 0.75, 0.99, 1]

/// Passthrough radiances to composite against, including both clipping ends.
let samplePassthrough: [SIMD3<Double>] = [
    SIMD3(0, 0, 0),
    SIMD3(1, 1, 1),
    SIMD3(0.5, 0.5, 0.5),
    SIMD3(0.8, 0.2, 0.05),
]

/// `SIMD4(xyz, w)` comes from the simd overlay; spelling it out here keeps the
/// tests independent of that convenience.
func rgba(_ rgb: SIMD3<Double>, _ alpha: Double) -> SIMD4<Double> {
    SIMD4(rgb.x, rgb.y, rgb.z, alpha)
}

func isClose(_ a: Double, _ b: Double, tolerance: Double = 1e-5) -> Bool {
    abs(a - b) <= tolerance
}

func isClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tolerance: Double = 1e-5) -> Bool {
    isClose(a.x, b.x, tolerance: tolerance)
        && isClose(a.y, b.y, tolerance: tolerance)
        && isClose(a.z, b.z, tolerance: tolerance)
}

func isClose(_ a: SIMD4<Float>, _ b: SIMD4<Double>, tolerance: Double = 1e-5) -> Bool {
    let a = a.doubles
    return isClose(a.x, b.x, tolerance: tolerance)
        && isClose(a.y, b.y, tolerance: tolerance)
        && isClose(a.z, b.z, tolerance: tolerance)
        && isClose(a.w, b.w, tolerance: tolerance)
}

@MainActor
extension AppModel {
    /// Drive the model the way the control panel's sliders and pickers do, then
    /// read back what the render thread would pick up.
    func configure(
        eye: TreatedEye? = nil,
        mode: OverlayMode? = nil,
        color: SIMD3<Double>? = nil,
        intensity: Double? = nil
    ) -> RenderParams {
        if let eye { treatedEye = eye }
        if let mode { self.mode = mode }
        if let color {
            red = color.x
            green = color.y
            blue = color.z
        }
        if let intensity { self.intensity = intensity }
        return renderParams.withLock { $0 }
    }

    var currentParams: RenderParams { renderParams.withLock { $0 } }
}
