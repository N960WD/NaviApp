import CarPlay
import UIKit

/// Entry point for the CarPlay scene (declared in Info.plist under
/// `CPTemplateApplicationSceneSessionRoleApplication`).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let controller = CarPlayController(interfaceController: interfaceController)
        self.controller = controller
        controller.connect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        controller?.disconnect()
        controller = nil
    }
}
