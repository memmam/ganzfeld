import Foundation
import GameController

/// Listens for paired game controllers (PS VR2 Sense controllers on
/// visionOS 26+, or any Bluetooth gamepad) and fires `onToggleUI` when a
/// menu-type button is pressed on any of them.
@MainActor
final class ControllerInput {
    var onToggleUI: () -> Void = {}

    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                Task { @MainActor in
                    self?.bind(controller)
                }
            }
        )
        GCController.controllers().forEach(bind)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func bind(_ controller: GCController) {
        controller.handlerQueue = .main

        let fire: (GCControllerButtonInput, Float, Bool) -> Void = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor in
                self?.onToggleUI()
            }
        }

        if let pad = controller.extendedGamepad {
            // On PSVR2 Sense pairs this is Options (right controller); Create
            // (left controller) commonly maps to buttonOptions/buttonHome.
            pad.buttonMenu.pressedChangedHandler = fire
            pad.buttonOptions?.pressedChangedHandler = fire
            pad.buttonHome?.pressedChangedHandler = fire
        } else {
            // Sense controllers exposed individually (or other profiles):
            // bind anything that looks like a menu/system button.
            for (name, button) in controller.physicalInputProfile.buttons {
                let key = name.lowercased()
                if key.contains("menu") || key.contains("options")
                    || key.contains("home") || key.contains("create") {
                    button.pressedChangedHandler = fire
                }
            }
        }
    }
}
