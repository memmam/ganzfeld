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
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
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

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPass.colorAttachments[0].loadAction = .clear
        // Transparent clear: passthrough shows wherever nothing is drawn.
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.depthAttachment.texture = drawable.depthTextures[0]
        renderPass.depthAttachment.loadAction = .clear
        renderPass.depthAttachment.clearDepth = 0  // reverse-Z: everything at infinity
        renderPass.depthAttachment.storeAction = .store
        if let rateMap = drawable.rasterizationRateMaps.first {
            renderPass.rasterizationRateMap = rateMap
        }
        let viewCount = drawable.views.count
        if layerRenderer.configuration.layout == .layered {
            renderPass.renderTargetArrayLength = viewCount
        }

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)!
        encoder.label = "GanzfeldOverlayEncoder"
        encoder.setRenderPipelineState(pipelineState)

        if viewCount > 1 {
            var viewMappings = (0..<viewCount).map { _ in
                // The shader writes the amplification index directly as the
                // render target array index, so the mappings add no offset.
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: 0,
                    renderTargetArrayIndexOffset: 0
                )
            }
            encoder.setVertexAmplificationCount(viewCount, viewMappings: &viewMappings)
        }

        let snapshot = params.withLock { $0 }
        var uniforms = ShaderUniforms(color: snapshot.rgba, targetEye: snapshot.targetEye)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
        frame.endSubmission()
    }
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}
