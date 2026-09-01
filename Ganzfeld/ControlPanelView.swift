import SwiftUI

struct ControlPanelView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var model = appModel

        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await toggleOverlay() }
                    } label: {
                        Label(
                            appModel.overlayActive ? "Stop Overlay" : "Start Overlay",
                            systemImage: appModel.overlayActive ? "eye.slash" : "eye"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appModel.overlayActive ? .red : .green)

                    Text("While the overlay runs, press Options/Menu on a paired game controller (e.g. PS VR2 Sense) to hide or show this window.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Treated Eye") {
                    Picker("Treated eye", selection: $model.treatedEye) {
                        ForEach(TreatedEye.allCases) { eye in
                            Text(eye.label).tag(eye)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(
                        appModel.treatedEye == .both
                            ? "Both eyes are treated — no passthrough reference eye."
                            : "The other eye keeps unmodified camera passthrough."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("Mode") {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(OverlayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(modeDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Color") {
                    channelSlider("R", value: $model.red, tint: .red)
                    channelSlider("G", value: $model.green, tint: .green)
                    channelSlider("B", value: $model.blue, tint: .blue)

                    HStack {
                        Text("Intensity")
                        Slider(value: $model.intensity, in: 0...1)
                        Text(String(format: "%.0f%%", model.intensity * 100))
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }

                    HStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: model.red, green: model.green, blue: model.blue))
                            .frame(width: 44, height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.secondary.opacity(0.5))
                            )
                        Text(hexString)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Ganzfeld")
        }
        .onAppear {
            appModel.controlWindowOpen = true
            appModel.openControlWindow = openWindow
            appModel.dismissControlWindow = dismissWindow
        }
        .onDisappear {
            appModel.controlWindowOpen = false
        }
    }

    private func channelSlider(_ label: String, value: Binding<Double>, tint: Color) -> some View {
        HStack {
            Text(label)
                .frame(width: 24, alignment: .leading)
            Slider(value: value, in: 0...1)
                .tint(tint)
            Text("\(Int((value.wrappedValue * 255).rounded()))")
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
    }

    private var modeDescription: String {
        switch appModel.mode {
        case .solid:
            return "Replaces the treated eye entirely with an opaque color surface."
        case .additive:
            return "Adds the color on top of passthrough in the treated eye."
        case .subtractive:
            return "Darkens passthrough toward the color's complement, approximating a subtractive filter."
        }
    }

    private var hexString: String {
        String(
            format: "#%02X%02X%02X",
            Int((appModel.red * 255).rounded()),
            Int((appModel.green * 255).rounded()),
            Int((appModel.blue * 255).rounded())
        )
    }

    private func toggleOverlay() async {
        if appModel.overlayActive {
            await dismissImmersiveSpace()
            appModel.overlayActive = false
        } else {
            switch await openImmersiveSpace(id: AppModel.immersiveSpaceID) {
            case .opened:
                appModel.overlayActive = true
            default:
                appModel.overlayActive = false
            }
        }
    }
}

#Preview(windowStyle: .automatic) {
    ControlPanelView()
        .environment(AppModel())
}
