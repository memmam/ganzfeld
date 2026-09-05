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

/// The outcome of a control-window toggle request.
enum ControlWindowIntent: String, Equatable {
    /// The window was asked to appear.
    case show
    /// The window was asked to go away for the duration of an overlay session.
    case hide
    /// The request was refused: hiding the window here would have left the
    /// app with no scenes at all, or an immersive-space transition was in
    /// flight and the overlay's real state was not yet settled.
    case ignored
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

    /// True while an open/dismiss of the immersive space is awaiting. Blocks
    /// re-entrant toggles and the controller window toggle during transitions.
    var overlayTransition = false

    /// Identity of the renderer currently driving the immersive space, so a
    /// stale renderer's invalidation (after a quick stop/restart) can't clear
    /// state belonging to its successor.
    @ObservationIgnored private var currentRendererToken: AnyObject?

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
            _ = self?.toggleControlWindow()
        }
        controllerInput.start()
    }

    /// Show/hide the control window, driven by a paired game controller
    /// (e.g. PS VR2 Sense) so the UI can be dismissed during a session and
    /// summoned back without hand input.
    ///
    /// Returns the decision that was taken, so the "never leave the app with
    /// zero scenes" rule is observable without a live window environment.
    @discardableResult
    func toggleControlWindow() -> ControlWindowIntent {
        if controlWindowOpen {
            // Never close the last scene: with no window and no immersive
            // space the app would suspend and controller input would stop.
            // overlayTransition also blocks the window from being hidden
            // while the immersive space is mid-dismissal.
            guard overlayActive, !overlayTransition else { return .ignored }
            dismissControlWindow?(id: Self.controlWindowID)
            return .hide
        } else {
            openControlWindow?(id: Self.controlWindowID)
            return .show
        }
    }

    /// Called (on the main actor) when a renderer session begins.
    func rendererStarted(token: AnyObject) {
        currentRendererToken = token
    }

    /// Called (on the main actor) when a renderer's layer is invalidated —
    /// via Stop Overlay or the Digital Crown. Ignored for stale renderers.
    func rendererInvalidated(token: AnyObject) {
        guard currentRendererToken === token else { return }
        currentRendererToken = nil
        overlayActive = false
        // If the control window was hidden for the session, bring it back:
        // otherwise the app would be left with zero scenes, suspend, and
        // stop receiving the controller input that could reopen it.
        if !controlWindowOpen {
            openControlWindow?(id: Self.controlWindowID)
        }
    }

    /// The premultiplied color that lands in the layer for the treated eye.
    /// The system compositor blends the layer over passthrough as
    /// `result = layer.rgb + (1 - layer.a) * passthrough`.
    ///
    /// The sliders/hex readout are sRGB display values; the shader writes
    /// linear light to an `_srgb` render target, so the color is converted to
    /// linear here to make the eye receive exactly what the swatch shows.
    /// In every mode, intensity 0 means "no effect" (untouched passthrough).
    private func pushParams() {
        let c = SIMD3<Float>(
            Self.srgbToLinear(Float(red)),
            Self.srgbToLinear(Float(green)),
            Self.srgbToLinear(Float(blue))
        )
        let k = Float(intensity)

        let rgba: SIMD4<Float>
        switch mode {
        case .solid:
            // result = k * C + (1 - k) * passthrough
            // Opaque color surface at full intensity, cross-fading back to
            // passthrough as intensity drops.
            rgba = SIMD4(c * k, k)
        case .additive:
            // result = passthrough + k * C
            rgba = SIMD4(c * k, 0)
        case .subtractive:
            // result = (1 - k * Y(C)) * passthrough
            // Removing specific channels from passthrough is impossible: the
            // compositor's source-over blend can only attenuate all channels
            // by one scalar alpha and add non-negative light, and apps cannot
            // read passthrough pixels. So subtractive attenuates neutrally,
            // weighted by the color's (linear, Rec. 709) luminance: black
            // subtracts nothing, white at 100% removes all light, and the
            // result can never be brighter than the passthrough it replaces.
            let luminance = simd_dot(c, SIMD3<Float>(0.2126, 0.7152, 0.0722))
            rgba = SIMD4(SIMD3<Float>(repeating: 0), k * luminance)
        }

        let params = RenderParams(rgba: rgba, targetEye: treatedEye.targetValue)
        renderParams.withLock { $0 = params }
    }

    /// The `#RRGGBB` readout for the current sliders. These are sRGB display
    /// values — the same numbers the swatch shows — not the linear values
    /// handed to the shader.
    var hexString: String {
        String(
            format: "#%02X%02X%02X",
            Self.displayByte(red),
            Self.displayByte(green),
            Self.displayByte(blue)
        )
    }

    /// A 0...1 channel as the 0...255 integer shown in the UI.
    static func displayByte(_ channel: Double) -> Int {
        Int((min(max(channel, 0), 1) * 255).rounded())
    }

    private static func srgbToLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
}
