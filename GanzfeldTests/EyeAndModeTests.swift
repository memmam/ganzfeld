import Testing

@testable import Ganzfeld

/// The eye selection is a contract between Swift and Metal: `targetValue` is
/// compared against a stereo view index in the fragment shader, and `both` is a
/// sentinel that must not collide with a real view index.
@Suite("Treated eye mapping")
struct TreatedEyeTests {

    @Test("view 0 is the left eye and view 1 the right")
    func viewIndices() {
        #expect(TreatedEye.left.targetValue == 0)
        #expect(TreatedEye.right.targetValue == 1)
    }

    @Test("the both-eyes sentinel is outside the range of real view indices")
    func bothEyesSentinel() {
        #expect(TreatedEye.both.targetValue == TreatedEye.bothEyesTarget)
        #expect(TreatedEye.bothEyesTarget == 2)
        #expect(TreatedEye.bothEyesTarget != TreatedEye.left.targetValue)
        #expect(TreatedEye.bothEyesTarget != TreatedEye.right.targetValue)
    }

    @Test("every case maps to a distinct target value")
    func targetValuesAreDistinct() {
        let values = TreatedEye.allCases.map(\.targetValue)
        #expect(Set(values).count == TreatedEye.allCases.count)
    }

    @Test("all three options are offered in the picker")
    func allCasesArePresent() {
        #expect(TreatedEye.allCases == [.left, .right, .both])
    }

    @Test("identity and label are derived from the raw value", arguments: TreatedEye.allCases)
    func identityAndLabel(eye: TreatedEye) {
        #expect(eye.id == eye.rawValue)
        #expect(eye.label == eye.rawValue.capitalized)
        #expect(!eye.label.isEmpty)
    }

    /// The shader's selection rule, mirrored here so the Swift side of the
    /// contract is pinned even when no GPU is available to run it.
    @Test("selection covers exactly the intended views", arguments: TreatedEye.allCases)
    func selectionRule(eye: TreatedEye) {
        func treats(_ view: UInt32) -> Bool {
            eye.targetValue == TreatedEye.bothEyesTarget || view == eye.targetValue
        }
        switch eye {
        case .left:
            #expect(treats(0))
            #expect(!treats(1))
        case .right:
            #expect(!treats(0))
            #expect(treats(1))
        case .both:
            #expect(treats(0))
            #expect(treats(1))
        }
    }
}

@Suite("Overlay mode")
struct OverlayModeTests {

    @Test("all three modes are offered in the picker")
    func allCasesArePresent() {
        #expect(OverlayMode.allCases == [.solid, .additive, .subtractive])
    }

    @Test("identity and label are derived from the raw value", arguments: OverlayMode.allCases)
    func identityAndLabel(mode: OverlayMode) {
        #expect(mode.id == mode.rawValue)
        #expect(mode.label == mode.rawValue.capitalized)
    }

    /// Raw values end up in nothing persisted today, but they are the stable
    /// names used in the README's mode table.
    @Test("raw values match the documented mode names")
    func rawValues() {
        #expect(OverlayMode.solid.rawValue == "solid")
        #expect(OverlayMode.additive.rawValue == "additive")
        #expect(OverlayMode.subtractive.rawValue == "subtractive")
    }
}

@Suite("Render parameter defaults")
struct RenderParamsTests {

    @Test("a default RenderParams is opaque red on the right eye")
    func defaults() {
        let params = RenderParams()
        #expect(params.rgba == SIMD4<Float>(1, 0, 0, 1))
        #expect(params.targetEye == TreatedEye.right.targetValue)
    }
}
