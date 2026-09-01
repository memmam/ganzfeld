import SwiftUI
import Observation
import os
import simd

/// Which eye(s) receive the color treatment. Untreated eyes keep camera
/// passthrough. View 0 of the stereo drawable is the left eye, view 1 the
/// right eye; `bothEyesTarget` is a sentinel the shader treats as matching
/// every view.
enum TreatedEye: String, CaseIterable, Identifiable {
    case left
    case right
    case both

    static let bothEyesTarget: UInt32 = 2

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var targetValue: UInt32 {
        switch self {
        case .left: return 0
        case .right: return 1
        case .both: return Self.bothEyesTarget
        }
    }
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
    var targetEye: UInt32 = TreatedEye.right.targetValue
}

@MainActor
@Observable
final class AppModel {
    static let immersiveSpaceID = "GanzfeldSpace"
    static let controlWindowID = "ControlPanel"

    /// Thread-safe handoff of UI state to the render loop.
    let renderParams = OSAllocatedUnfairLock(initialState: RenderParams())

    let controllerInput = ControllerInput()

    var overlayActive = false

    /// Tracked from ControlPanelView's onAppear/onDisappear.
    var controlWindowOpen = false

    /// Window actions stashed from the control panel's environment so the
    /// controller handler can reopen the window after it has been dismissed.
    @ObservationIgnored var openControlWindow: OpenWindowAction?
    @ObservationIgnored var dismissControlWindow: DismissWindowAction?

    var treatedEye: TreatedEye = .right { didSet { pushParams() } }
    var mode: OverlayMode = .solid { didSet { pushParams() } }
    var red: Double = 1.0 { didSet { pushParams() } }
    var green: Double = 0.0 { didSet { pushParams() } }
    var blue: Double = 0.0 { didSet { pushParams() } }
    /// Strength of the effect, 0...1.
    var intensity: Double = 1.0 { didSet { pushParams() } }

    init() {
        pushParams()
        controllerInput.onToggleUI = { [weak self] in
            self?.toggleControlWindow()
        }
        controllerInput.start()
    }

    /// Show/hide the control window, driven by a paired game controller
    /// (e.g. PS VR2 Sense) so the UI can be dismissed during a session and
    /// summoned back without hand input.
    func toggleControlWindow() {
        if controlWindowOpen {
            // Never close the last scene: with no window and no immersive
            // space the app would suspend and controller input would stop.
            guard overlayActive else { return }
            dismissControlWindow?(id: Self.controlWindowID)
        } else {
            openControlWindow?(id: Self.controlWindowID)
        }
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

        let params = RenderParams(rgba: rgba, targetEye: treatedEye.targetValue)
        renderParams.withLock { $0 = params }
    }
}
