import SwiftUI
import CompositorServices

@main
struct GanzfeldApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup(id: AppModel.controlWindowID) {
            ControlPanelView()
                .environment(appModel)
        }
        .defaultSize(width: 460, height: 700)

        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            CompositorLayer(configuration: GanzfeldLayerConfiguration()) { [appModel] layerRenderer in
                let token = NSObject()
                Task { @MainActor in
                    appModel.rendererStarted(token: token)
                }
                let renderer = Renderer(
                    layerRenderer: layerRenderer,
                    params: appModel.renderParams,
                    onInvalidated: {
                        Task { @MainActor in
                            appModel.rendererInvalidated(token: token)
                        }
                    }
                )
                renderer.startRenderLoop()
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

struct GanzfeldLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(
        capabilities: LayerRenderer.Capabilities,
        configuration: inout LayerRenderer.Configuration
    ) {
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float

        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled

        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions =
            foveationEnabled ? [.foveationEnabled] : []
        let supportedLayouts = capabilities.supportedLayouts(options: options)
        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated
    }
}
