import SwiftUI
import AVKit

/// System-standard, app-only AirPlay picker. On macOS the picker must be
/// associated with an AVPlayer; `AirPlayOutputController` supplies its live
/// audio-only HLS player.
struct AirPlayRoutePickerView: NSViewRepresentable {
    @ObservedObject var controller: AirPlayOutputController
    let identifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> AirPlayRoutePickerContainer {
        let container = AirPlayRoutePickerContainer(frame: .zero)
        container.install(controller.routePicker(
            identifier: identifier,
            delegate: context.coordinator))
        return container
    }

    func updateNSView(
        _ nsView: AirPlayRoutePickerContainer,
        context: Context
    ) {
        context.coordinator.controller = controller
        nsView.install(controller.routePicker(
            identifier: identifier,
            delegate: context.coordinator))
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var controller: AirPlayOutputController

        init(controller: AirPlayOutputController) {
            self.controller = controller
        }

        func routePickerViewWillBeginPresentingRoutes(
            _ routePickerView: AVRoutePickerView
        ) {
            Task { @MainActor in
                controller.prepareForRouteSelection()
            }
        }

        func routePickerViewDidEndPresentingRoutes(
            _ routePickerView: AVRoutePickerView
        ) {
            Task { @MainActor in
                controller.routePickerDidClose()
            }
        }
    }
}

final class AirPlayRoutePickerContainer: NSView {
    private weak var picker: AVRoutePickerView?

    func install(_ picker: AVRoutePickerView) {
        guard self.picker !== picker else { return }
        if let oldSuperview = picker.superview {
            NSLayoutConstraint.deactivate(
                oldSuperview.constraints.filter {
                    ($0.firstItem as? NSView) === picker ||
                    ($0.secondItem as? NSView) === picker
                })
        }
        picker.removeFromSuperview()
        self.picker = picker
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor),
            picker.topAnchor.constraint(equalTo: topAnchor),
            picker.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
