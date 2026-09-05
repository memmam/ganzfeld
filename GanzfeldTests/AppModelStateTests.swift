import Testing
import Foundation
import simd

@testable import Ganzfeld

@MainActor
@Suite("AppModel defaults and live updates")
struct AppModelStateTests {

    @Test("a fresh model starts as opaque red on the right eye")
    func initialState() {
        let model = AppModel()
        #expect(model.treatedEye == .right)
        #expect(model.mode == .solid)
        #expect(model.red == 1)
        #expect(model.green == 0)
        #expect(model.blue == 0)
        #expect(model.intensity == 1)
        #expect(!model.overlayActive)
        #expect(!model.overlayTransition)
        #expect(!model.controlWindowOpen)
    }

    /// `init` must publish before the render thread ever reads, or the first
    /// frames would use a stale default.
    @Test("render parameters are published during init")
    func paramsPublishedAtInit() {
        let params = AppModel().currentParams
        #expect(params.rgba == SIMD4<Float>(1, 0, 0, 1))
        #expect(params.targetEye == TreatedEye.right.targetValue)
    }

    @Test("changing the treated eye republishes immediately", arguments: TreatedEye.allCases)
    func eyeChangeIsPublished(eye: TreatedEye) {
        let model = AppModel()
        model.treatedEye = eye
        #expect(model.currentParams.targetEye == eye.targetValue)
    }

    @Test("changing the mode republishes immediately", arguments: OverlayMode.allCases)
    func modeChangeIsPublished(mode: OverlayMode) {
        let model = AppModel()
        model.mode = mode
        let expected = AppModel().configure(mode: mode, color: SIMD3(1, 0, 0), intensity: 1)
        #expect(model.currentParams.rgba == expected.rgba)
    }

    @Test("each colour slider republishes on its own")
    func colorChangesArePublished() {
        let model = AppModel()

        model.red = 0
        #expect(model.currentParams.rgba.x == 0)

        model.green = 1
        #expect(model.currentParams.rgba.y == 1)

        model.blue = 1
        #expect(model.currentParams.rgba.z == 1)
    }

    @Test("the intensity slider republishes on its own")
    func intensityChangeIsPublished() {
        let model = AppModel()
        model.intensity = 0.5
        #expect(isClose(Double(model.currentParams.rgba.w), 0.5, tolerance: 1e-6))
        model.intensity = 0
        #expect(model.currentParams.rgba == SIMD4<Float>(0, 0, 0, 0))
    }

    /// The eye selection travels alongside the colour in one snapshot, so a
    /// frame can never mix a new colour with an old eye.
    @Test("colour and eye are published as a single snapshot")
    func snapshotIsCoherent() {
        let model = AppModel()
        model.treatedEye = .left
        model.mode = .additive
        model.red = 0
        model.blue = 1
        let params = model.currentParams
        #expect(params.targetEye == TreatedEye.left.targetValue)
        #expect(params.rgba.w == 0)
        #expect(params.rgba.x == 0)
        #expect(params.rgba.z == 1)
    }
}

@MainActor
@Suite("Hex readout")
struct HexReadoutTests {

    @Test(
        "sliders render as the sRGB hex a user would recognise",
        arguments: zip(
            [
                SIMD3<Double>(1, 0, 0),
                SIMD3<Double>(0, 0, 0),
                SIMD3<Double>(1, 1, 1),
                SIMD3<Double>(0.5, 0.5, 0.5),
                SIMD3<Double>(0, 1, 0),
                SIMD3<Double>(0, 0, 1),
            ],
            ["#FF0000", "#000000", "#FFFFFF", "#808080", "#00FF00", "#0000FF"]
        )
    )
    func hexStrings(color: SIMD3<Double>, expected: String) {
        let model = AppModel()
        model.red = color.x
        model.green = color.y
        model.blue = color.z
        #expect(model.hexString == expected)
    }

    @Test("the readout is always a # plus six uppercase hex digits")
    func hexFormatIsStable() {
        let model = AppModel()
        for step in 0...32 {
            model.red = Double(step) / 32
            model.green = 1 - Double(step) / 32
            model.blue = Double(step % 5) / 4
            let hex = model.hexString
            #expect(hex.count == 7)
            #expect(hex.hasPrefix("#"))
            #expect(hex.dropFirst().allSatisfy { "0123456789ABCDEF".contains($0) })
        }
    }

    @Test("channel bytes round to nearest and clamp to 0...255")
    func displayByteBehaviour() {
        #expect(AppModel.displayByte(0) == 0)
        #expect(AppModel.displayByte(1) == 255)
        #expect(AppModel.displayByte(0.5) == 128)
        #expect(AppModel.displayByte(1.0 / 255) == 1)
        #expect(AppModel.displayByte(-1) == 0)
        #expect(AppModel.displayByte(2) == 255)
    }

    /// The hex readout describes the stimulus in display terms; it must not be
    /// contaminated by the linear conversion the shader receives.
    @Test("the readout is the sRGB value, not the linear one")
    func hexIsNotLinearized() {
        let model = AppModel()
        model.red = 0.5
        model.green = 0.5
        model.blue = 0.5
        #expect(model.hexString == "#808080")
        // The linear value handed to the shader is much darker.
        #expect(Double(model.currentParams.rgba.x) < 0.25)
    }
}

@MainActor
@Suite("Renderer lifecycle")
struct RendererLifecycleTests {

    @Test("the current renderer's invalidation stops the overlay")
    func currentRendererClearsState() {
        let model = AppModel()
        let token = NSObject()
        model.rendererStarted(token: token)
        model.overlayActive = true

        model.rendererInvalidated(token: token)
        #expect(!model.overlayActive)
    }

    /// A quick Stop/Start leaves the old renderer's thread alive for a moment;
    /// its invalidation must not tear down its successor's session.
    @Test("a stale renderer's invalidation is ignored")
    func staleRendererIsIgnored() {
        let model = AppModel()
        let first = NSObject()
        model.rendererStarted(token: first)

        let second = NSObject()
        model.rendererStarted(token: second)
        model.overlayActive = true

        model.rendererInvalidated(token: first)
        #expect(model.overlayActive, "the superseded renderer must not stop the new session")

        model.rendererInvalidated(token: second)
        #expect(!model.overlayActive)
    }

    @Test("invalidation is idempotent")
    func invalidationIsIdempotent() {
        let model = AppModel()
        let token = NSObject()
        model.rendererStarted(token: token)
        model.overlayActive = true
        model.rendererInvalidated(token: token)

        // A second delivery for the same renderer must not clobber a session
        // that has since been restarted.
        model.overlayActive = true
        model.rendererInvalidated(token: token)
        #expect(model.overlayActive)
    }

    @Test("invalidation before any renderer started is ignored")
    func invalidationWithoutStartIsIgnored() {
        let model = AppModel()
        model.overlayActive = true
        model.rendererInvalidated(token: NSObject())
        #expect(model.overlayActive)
    }
}

/// The rule that keeps the app from being left with zero scenes: with no window
/// and no immersive space, visionOS suspends the app and controller input — the
/// only way back — stops arriving.
@MainActor
@Suite("Control window toggle")
struct ControlWindowToggleTests {

    private func makeModel(
        windowOpen: Bool,
        overlayActive: Bool,
        transition: Bool
    ) -> AppModel {
        let model = AppModel()
        model.controlWindowOpen = windowOpen
        model.overlayActive = overlayActive
        model.overlayTransition = transition
        return model
    }

    @Test("a closed window is always summoned back")
    func closedWindowIsAlwaysShown() {
        for overlayActive in [true, false] {
            for transition in [true, false] {
                let model = makeModel(
                    windowOpen: false,
                    overlayActive: overlayActive,
                    transition: transition
                )
                #expect(model.toggleControlWindow() == .show)
            }
        }
    }

    @Test("the window hides only while the overlay is genuinely running")
    func hidesDuringOverlay() {
        let model = makeModel(windowOpen: true, overlayActive: true, transition: false)
        #expect(model.toggleControlWindow() == .hide)
    }

    @Test("hiding is refused with no immersive space to fall back on")
    func refusesToCloseTheLastScene() {
        let model = makeModel(windowOpen: true, overlayActive: false, transition: false)
        #expect(model.toggleControlWindow() == .ignored)
    }

    @Test("hiding is refused mid-transition", arguments: [true, false])
    func refusesDuringTransition(overlayActive: Bool) {
        let model = makeModel(windowOpen: true, overlayActive: overlayActive, transition: true)
        #expect(model.toggleControlWindow() == .ignored)
    }

    @Test("a refused toggle leaves the model untouched")
    func refusalHasNoSideEffects() {
        let model = makeModel(windowOpen: true, overlayActive: false, transition: false)
        _ = model.toggleControlWindow()
        #expect(model.controlWindowOpen)
        #expect(!model.overlayActive)
        #expect(!model.overlayTransition)
    }

    /// The controller handler is wired up in `init` and routes through
    /// `toggleControlWindow`, so the zero-scene guard covers it too.
    @Test("the game controller handler cannot close the last scene")
    func controllerHandlerRespectsTheGuard() {
        let model = makeModel(windowOpen: true, overlayActive: false, transition: false)
        model.controllerInput.onToggleUI()
        #expect(model.controlWindowOpen, "a refused hide must not desync the tracked state")
        #expect(!model.overlayActive)
    }
}
