import Testing
import Foundation
import Metal
import simd

@testable import Ganzfeld

enum ShaderTestError: Error, CustomStringConvertible {
    case noMetalDevice
    case noDefaultLibrary
    case missingFunction(String)
    case encodingFailed

    var description: String {
        switch self {
        case .noMetalDevice: return "no Metal device is available"
        case .noDefaultLibrary: return "the host app bundle has no default.metallib"
        case .missingFunction(let name): return "Shaders.metal does not define \(name)"
        case .encodingFailed: return "could not encode the render pass"
        }
    }
}

/// Renders the real `ganzfeldVertex`/`ganzfeldFragment` pair from the app
/// bundle's shader library into an offscreen target with the same pixel formats
/// the compositor layer uses, so the eye-selection rule and the linear→sRGB
/// round trip are checked on a GPU rather than restated in Swift.
struct ShaderHarness {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    static let size = 8
    static let colorFormat = MTLPixelFormat.bgra8Unorm_srgb
    static let depthFormat = MTLPixelFormat.depth32Float

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ShaderTestError.noMetalDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw ShaderTestError.noMetalDevice }
        self.queue = queue

        // Hosted test bundle: Bundle.main is the app, which is where the
        // compiled Shaders.metal lives.
        let library = device.makeDefaultLibrary()
            ?? Bundle(identifier: "dev.ewilliams.ganzfeld").flatMap {
                try? device.makeDefaultLibrary(bundle: $0)
            }
        guard let library else { throw ShaderTestError.noDefaultLibrary }
        self.library = library
    }

    /// Built exactly the way `Renderer` builds its pipeline.
    func makePipeline(amplificationCount: Int = 1) throws -> MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: "ganzfeldVertex") else {
            throw ShaderTestError.missingFunction("ganzfeldVertex")
        }
        guard let fragment = library.makeFunction(name: "ganzfeldFragment") else {
            throw ShaderTestError.missingFunction("ganzfeldFragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "GanzfeldOverlayPipelineTest"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.colorFormat
        descriptor.depthAttachmentPixelFormat = Self.depthFormat
        descriptor.inputPrimitiveTopology = .triangle
        if amplificationCount > 1 {
            descriptor.maxVertexAmplificationCount = amplificationCount
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func makeTextures(arrayLength: Int) throws -> (MTLTexture, MTLTexture) {
        let color = MTLTextureDescriptor()
        color.pixelFormat = Self.colorFormat
        color.width = Self.size
        color.height = Self.size
        color.usage = [.renderTarget, .shaderRead]
        color.storageMode = .shared
        if arrayLength > 1 {
            color.textureType = .type2DArray
            color.arrayLength = arrayLength
        }

        let depth = MTLTextureDescriptor()
        depth.pixelFormat = Self.depthFormat
        depth.width = Self.size
        depth.height = Self.size
        depth.usage = .renderTarget
        depth.storageMode = .private
        if arrayLength > 1 {
            depth.textureType = .type2DArray
            depth.arrayLength = arrayLength
        }

        guard let colorTexture = device.makeTexture(descriptor: color),
              let depthTexture = device.makeTexture(descriptor: depth)
        else { throw ShaderTestError.encodingFailed }
        return (colorTexture, depthTexture)
    }

    /// One pass with no amplification, mirroring `Renderer`'s `.dedicated`
    /// layout branch: one view per pass, selected by `viewOffset`.
    func render(uniforms: ShaderUniforms) throws -> [SIMD4<Double>] {
        let (color, depth) = try makeTextures(arrayLength: 1)
        try encode(pipeline: try makePipeline(), color: color, depth: depth, layers: 1) { encoder in
            var uniforms = uniforms
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        }
        return [try readBack(color, slice: 0)]
    }

    /// One amplified pass writing both eyes at once, mirroring the `.layered`
    /// branch. Returns one colour per view.
    func renderAmplified(uniforms: ShaderUniforms, views: Int = 2) throws -> [SIMD4<Double>] {
        let (color, depth) = try makeTextures(arrayLength: views)
        let pipeline = try makePipeline(amplificationCount: views)
        try encode(pipeline: pipeline, color: color, depth: depth, layers: views) { encoder in
            var mappings = (0..<views).map { index in
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32(index),
                    renderTargetArrayIndexOffset: UInt32(index)
                )
            }
            encoder.setVertexAmplificationCount(views, viewMappings: &mappings)
            var uniforms = uniforms
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        }
        return try (0..<views).map { try readBack(color, slice: $0) }
    }

    private func encode(
        pipeline: MTLRenderPipelineState,
        color: MTLTexture,
        depth: MTLTexture,
        layers: Int,
        configure: (MTLRenderCommandEncoder) -> Void
    ) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        // The same transparent clear the renderer uses: anything the shader
        // declines to touch stays as untouched passthrough.
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .dontCare
        if layers > 1 {
            pass.renderTargetArrayLength = layers
        }

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { throw ShaderTestError.encodingFailed }

        encoder.setRenderPipelineState(pipeline)
        let viewport = MTLViewport(
            originX: 0, originY: 0,
            width: Double(Self.size), height: Double(Self.size),
            znear: 0, zfar: 1
        )
        encoder.setViewports(Array(repeating: viewport, count: layers))
        configure(encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// Reads the slice back and asserts the fullscreen triangle really covered
    /// every pixel, then returns the common value as 0...1 components.
    private func readBack(_ texture: MTLTexture, slice: Int) throws -> SIMD4<Double> {
        let count = Self.size * Self.size
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let region = MTLRegionMake2D(0, 0, Self.size, Self.size)
        // Metal requires bytesPerImage to be 0 for anything that is not a 3D
        // texture or a texture array.
        let bytesPerImage = texture.textureType == .type2DArray ? count * 4 : 0
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: Self.size * 4,
                bytesPerImage: bytesPerImage,
                from: region,
                mipmapLevel: 0,
                slice: slice
            )
        }
        let first = Array(bytes[0..<4])
        for pixel in 0..<count {
            let px = Array(bytes[(pixel * 4)..<(pixel * 4 + 4)])
            #expect(px == first, "the fullscreen triangle left pixel \(pixel) uncovered")
        }
        // bgra8Unorm stores B, G, R, A in that byte order.
        return SIMD4(
            Double(first[2]) / 255,
            Double(first[1]) / 255,
            Double(first[0]) / 255,
            Double(first[3]) / 255
        )
    }
}

/// One 8-bit code point of slack, so rounding in the sRGB encode never fails a
/// test that is really about which eye got painted.
private let byteTolerance = 2.0 / 255

private func expectPixel(
    _ actual: SIMD4<Double>,
    linear expected: SIMD4<Double>,
    _ comment: Comment
) {
    let encoded = SIMD4(
        Reference.linearToSRGB(expected.x),
        Reference.linearToSRGB(expected.y),
        Reference.linearToSRGB(expected.z),
        expected.w  // alpha is stored linearly even in an _srgb format
    )
    #expect(abs(actual.x - encoded.x) <= byteTolerance, comment)
    #expect(abs(actual.y - encoded.y) <= byteTolerance, comment)
    #expect(abs(actual.z - encoded.z) <= byteTolerance, comment)
    #expect(abs(actual.w - encoded.w) <= byteTolerance, comment)
}

@MainActor
@Suite("Shader rendering", .serialized)
struct ShaderRenderTests {

    @Test("the production pipeline configuration compiles")
    func pipelineCompiles() throws {
        let harness = try ShaderHarness()
        _ = try harness.makePipeline()
    }

    @Test(
        "each eye selection paints exactly the intended view",
        arguments: TreatedEye.allCases, [0, 1] as [Int]
    )
    func eyeSelection(eye: TreatedEye, viewIndex: Int) throws {
        let harness = try ShaderHarness()
        let params = AppModel().configure(
            eye: eye,
            mode: .solid,
            color: SIMD3(1, 0, 0),
            intensity: 1
        )
        let pixels = try harness.render(
            uniforms: ShaderUniforms(
                color: params.rgba,
                targetEye: params.targetEye,
                viewOffset: UInt32(viewIndex)
            )
        )

        let treated = eye == .both || UInt32(viewIndex) == eye.targetValue
        if treated {
            expectPixel(pixels[0], linear: SIMD4(1, 0, 0, 1), "\(eye) must paint view \(viewIndex)")
        } else {
            expectPixel(
                pixels[0],
                linear: SIMD4(0, 0, 0, 0),
                "\(eye) must leave view \(viewIndex) as passthrough"
            )
        }
    }

    /// The README's promise: the treated eye receives the colour the swatch
    /// shows. That only holds if the sRGB→linear conversion in `AppModel` and
    /// the `_srgb` render target cancel out exactly.
    @Test(
        "solid at full intensity reproduces the swatch colour",
        arguments: [
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(0, 0, 1),
            SIMD3<Double>(0.5, 0.5, 0.5),
            SIMD3<Double>(0.9, 0.4, 0.1),
            SIMD3<Double>(1, 1, 1),
            SIMD3<Double>(0, 0, 0),
        ]
    )
    func swatchRoundTrip(color: SIMD3<Double>) throws {
        let harness = try ShaderHarness()
        let params = AppModel().configure(
            eye: .both,
            mode: .solid,
            color: color,
            intensity: 1
        )
        let pixel = try harness.render(
            uniforms: ShaderUniforms(color: params.rgba, targetEye: params.targetEye)
        )[0]

        // Compare in display space: the bytes in the target should be the
        // slider values, not the linear ones.
        #expect(abs(pixel.x - color.x) <= byteTolerance)
        #expect(abs(pixel.y - color.y) <= byteTolerance)
        #expect(abs(pixel.z - color.z) <= byteTolerance)
        #expect(abs(pixel.w - 1) <= byteTolerance)
    }

    @Test("additive writes zero alpha so passthrough survives")
    func additiveWritesZeroAlpha() throws {
        let harness = try ShaderHarness()
        let params = AppModel().configure(
            eye: .both,
            mode: .additive,
            color: SIMD3(0.9, 0.4, 0.1),
            intensity: 0.5
        )
        let pixel = try harness.render(
            uniforms: ShaderUniforms(color: params.rgba, targetEye: params.targetEye)
        )[0]
        #expect(pixel.w == 0, "an additive layer must never occlude passthrough")
        expectPixel(pixel, linear: params.rgba.doubles, "additive colour reached the target")
    }

    @Test("subtractive writes alpha only")
    func subtractiveWritesAlphaOnly() throws {
        let harness = try ShaderHarness()
        let params = AppModel().configure(
            eye: .both,
            mode: .subtractive,
            color: SIMD3(1, 1, 1),
            intensity: 0.5
        )
        let pixel = try harness.render(
            uniforms: ShaderUniforms(color: params.rgba, targetEye: params.targetEye)
        )[0]
        #expect(pixel.x == 0)
        #expect(pixel.y == 0)
        #expect(pixel.z == 0)
        #expect(abs(pixel.w - 0.5) <= byteTolerance, "white at 50% must remove half the light")
    }

    @Test("zero intensity paints nothing at all", arguments: OverlayMode.allCases)
    func zeroIntensityPaintsNothing(mode: OverlayMode) throws {
        let harness = try ShaderHarness()
        let params = AppModel().configure(
            eye: .both,
            mode: mode,
            color: SIMD3(0.9, 0.4, 0.1),
            intensity: 0
        )
        let pixel = try harness.render(
            uniforms: ShaderUniforms(color: params.rgba, targetEye: params.targetEye)
        )[0]
        #expect(pixel == SIMD4<Double>(0, 0, 0, 0))
    }

    /// The layered layout the app prefers on device: one amplified pass fills
    /// both eyes, and the render target array index picks the view.
    @Test(
        "an amplified pass selects per layer",
        .enabled(if: MTLCreateSystemDefaultDevice()?.supportsVertexAmplificationCount(2) == true),
        arguments: TreatedEye.allCases
    )
    func amplifiedSelection(eye: TreatedEye) throws {
        let harness = try ShaderHarness()
        let params = AppModel().configure(
            eye: eye,
            mode: .solid,
            color: SIMD3(0, 1, 0),
            intensity: 1
        )
        let pixels = try harness.renderAmplified(
            uniforms: ShaderUniforms(color: params.rgba, targetEye: params.targetEye)
        )

        for (viewIndex, pixel) in pixels.enumerated() {
            let treated = eye == .both || UInt32(viewIndex) == eye.targetValue
            expectPixel(
                pixel,
                linear: treated ? SIMD4(0, 1, 0, 1) : SIMD4(0, 0, 0, 0),
                "\(eye), layer \(viewIndex)"
            )
        }
    }
}
