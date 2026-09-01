import SwiftUI
import Observation
import os
import simd

/// Which eye receives the color treatment. The other eye keeps camera passthrough.
/// View 0 of the stereo drawable is the left eye, view 1 the right eye.
enum TreatedEye: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var viewIndex: UInt32 { self == .left ? 0 : 1 }
}

/// How the color is composited over the treated eye.
enum OverlayMode: String, CaseIterable, Identifiable {
    /// Opaque color surface: passthrough for that eye is fully replaced.
    case solid
    /// Color is added on top of passthrough (premultiplied color with alpha 0).
    case additive
    /// Passthrough is darkened toward the complement of the color, approximating
    /// a subtractive filter of that color.
    case subtractive

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Snapshot of everything the render thread needs for a frame.
/// `rgba` is the final premultiplied-alpha value written for the treated eye;
/// the untreated eye is always written as (0, 0, 0, 0) so passthrough shows.
struct RenderParams: Sendable {
    var rgba: SIMD4<Float> = SIMD4(1, 0, 0, 1)
    var targetEye: UInt32 = TreatedEye.right.viewIndex
}

@MainActor
@Observable
final class AppModel {
    static let immersiveSpaceID = "GanzfeldSpace"

    /// Thread-safe handoff of UI state to the render loop.
    let renderParams = OSAllocatedUnfairLock(initialState: RenderParams())

    var overlayActive = false

    var treatedEye: TreatedEye = .right { didSet { pushParams() } }
    var mode: OverlayMode = .solid { didSet { pushParams() } }
    var red: Double = 1.0 { didSet { pushParams() } }
    var green: Double = 0.0 { didSet { pushParams() } }
    var blue: Double = 0.0 { didSet { pushParams() } }
    /// Strength of the effect, 0...1.
    var intensity: Double = 1.0 { didSet { pushParams() } }

    init() {
        pushParams()
    }

    /// The premultiplied color that lands in the layer for the treated eye.
    /// The system compositor blends the layer over passthrough as
    /// `result = layer.rgb + (1 - layer.a) * passthrough`.
    private func pushParams() {
        let c = SIMD3<Float>(Float(red), Float(green), Float(blue))
        let k = Float(intensity)

        let rgba: SIMD4<Float>
        switch mode {
        case .solid:
            // result = k * C
            rgba = SIMD4(c * k, 1)
        case .additive:
            // result = passthrough + k * C
            rgba = SIMD4(c * k, 0)
        case .subtractive:
            // result = (1 - k) * passthrough + k * (1 - C)
            // Apps cannot read passthrough pixels, so true per-channel
            // subtraction is impossible; this darkens toward the complement.
            rgba = SIMD4((SIMD3<Float>(repeating: 1) - c) * k, k)
        }

        let params = RenderParams(rgba: rgba, targetEye: treatedEye.viewIndex)
        renderParams.withLock { $0 = params }
    }
}
