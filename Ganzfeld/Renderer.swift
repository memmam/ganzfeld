import CompositorServices
import Foundation
import Metal
import ARKit
import os
import simd

/// Must match `Uniforms` in Shaders.metal.
struct ShaderUniforms {
    var color: SIMD4<Float>
    var targetEye: UInt32
    var viewOffset: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

final class Renderer {
    private let layerRenderer: LayerRenderer
    private let params: OSAllocatedUnfairLock<RenderParams>
    private let onInvalidated: () -> Void

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    init(
        layerRenderer: LayerRenderer,
        params: OSAllocatedUnfairLock<RenderParams>,
        onInvalidated: @escaping () -> Void
    ) {
        self.layerRenderer = layerRenderer
        self.params = params
        self.onInvalidated = onInvalidated
        self.device = layerRenderer.device
        self.commandQueue = device.makeCommandQueue()!

        let library = device.makeDefaultLibrary()!
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "GanzfeldOverlayPipeline"
        descriptor.vertexFunction = library.makeFunction(name: "ganzfeldVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "ganzfeldFragment")
        descriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        descriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        descriptor.inputPrimitiveTopology = .triangle
        if device.supportsVertexAmplificationCount(2) {
            descriptor.maxVertexAmplificationCount = 2
        }
        self.pipelineState = try! device.makeRenderPipelineState(descriptor: descriptor)
    }

    func startRenderLoop() {
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                // Device pose is only used for reprojection hints; the overlay
                // is head-locked and uniform, so rendering continues without it.
                print("ARKitSession failed to run: \(error)")
            }
        }

        let renderThread = Thread { [self] in
            renderLoop()
        }
        renderThread.name = "Ganzfeld Render Thread"
        renderThread.start()
    }

    private func renderLoop() {
        while true {
            switch layerRenderer.state {
            case .invalidated:
                arSession.stop()
                onInvalidated()
                return
            case .paused:
                layerRenderer.waitUntilRunning()
            case .running:
                autoreleasepool {
                    renderFrame()
                }
            @unknown default:
                layerRenderer.waitUntilRunning()
            }
        }
    }

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        guard let drawable = frame.queryDrawable() else { return }
        frame.startSubmission()

        if worldTracking.state == .running {
            let presentation = drawable.frameTiming.presentationTime
            let timestamp = LayerRenderer.Clock.Instant.epoch
                .duration(to: presentation).timeInterval
            drawable.deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: timestamp)
        }

        let commandBuffer = commandQueue.makeCommandBuffer()!
        commandBuffer.label = "GanzfeldFrame"

        let snapshot = params.withLock { $0 }
        var targetEye = snapshot.targetEye
        if drawable.views.count == 1 {
            // Mono drawable (e.g. the simulator): there is no view index 1, so
            // a Left/Right selection would otherwise render nothing. Always
            // show the effect in the single view.
            targetEye = TreatedEye.bothEyesTarget
        }

        switch layerRenderer.configuration.layout {
        case .dedicated:
            // Each view has its own non-array texture and needs its own pass.
            for (viewIndex, view) in drawable.views.enumerated() {
                let uniforms = ShaderUniforms(
                    color: snapshot.rgba,
                    targetEye: targetEye,
                    viewOffset: UInt32(viewIndex)
                )
                encodePass(
                    commandBuffer: commandBuffer,
                    drawable: drawable,
                    textureIndex: view.textureMap.textureIndex,
                    rateMapIndex: viewIndex,
                    viewports: [view.textureMap.viewport],
                    renderTargetArrayLength: 0,
                    amplificationCount: 1,
                    uniforms: uniforms
                )
            }
        default:
            // Layered (or shared) layout: one pass, amplified across views.
            let uniforms = ShaderUniforms(color: snapshot.rgba, targetEye: targetEye)
            encodePass(
                commandBuffer: commandBuffer,
                drawable: drawable,
                textureIndex: 0,
                rateMapIndex: 0,
                viewports: drawable.views.map { $0.textureMap.viewport },
                renderTargetArrayLength: drawable.views.count,
                amplificationCount: drawable.views.count,
                uniforms: uniforms
            )
        }

        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
        frame.endSubmission()
    }

    private func encodePass(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        textureIndex: Int,
        rateMapIndex: Int,
        viewports: [MTLViewport],
        renderTargetArrayLength: Int,
        amplificationCount: Int,
        uniforms: ShaderUniforms
    ) {
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.colorTextures[textureIndex]
        renderPass.colorAttachments[0].loadAction = .clear
        // Transparent clear: passthrough shows wherever nothing is drawn.
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.depthAttachment.texture = drawable.depthTextures[textureIndex]
        renderPass.depthAttachment.loadAction = .clear
        renderPass.depthAttachment.clearDepth = 0  // reverse-Z: everything at infinity
        renderPass.depthAttachment.storeAction = .store
        if !drawable.rasterizationRateMaps.isEmpty {
            let index = min(rateMapIndex, drawable.rasterizationRateMaps.count - 1)
            renderPass.rasterizationRateMap = drawable.rasterizationRateMaps[index]
        }
        if renderTargetArrayLength > 0 {
            renderPass.renderTargetArrayLength = renderTargetArrayLength
        }

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)!
        encoder.label = "GanzfeldOverlayEncoder"
        encoder.setRenderPipelineState(pipelineState)

        // With a rasterization rate map bound, viewport coordinates are
        // logical rather than physical, so the drawable's per-view viewports
        // must be set explicitly for the triangle to cover the full field.
        encoder.setViewports(viewports)

        if amplificationCount > 1 {
            // The mappings supply both the render target array index and the
            // viewport index for each amplified view; the vertex function
            // outputs neither.
            var viewMappings = (0..<amplificationCount).map { index in
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32(index),
                    renderTargetArrayIndexOffset: UInt32(index)
                )
            }
            encoder.setVertexAmplificationCount(amplificationCount, viewMappings: &viewMappings)
        }

        var uniforms = uniforms
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}
