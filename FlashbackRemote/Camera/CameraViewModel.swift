import Foundation
import Combine

@MainActor
final class CameraViewModel: ObservableObject {
    @Published var rollLength: Int {
        didSet { UserDefaults.standard.set(rollLength, forKey: "lastRollLength") }
    }
    @Published var isConfiguring: Bool = false

    init() {
        let saved = UserDefaults.standard.integer(forKey: "lastRollLength")
        rollLength = saved > 0 ? min(saved, 99) : 36
    }

    func configure(using bleController: BLEController) {
        bleController.configureAndStartWiFi(rollLength: rollLength)
    }

    func setRollOnly(using bleController: BLEController) {
        bleController.writeRollOnly(rollLength: rollLength)
    }

    func startWiFiOnly(using bleController: BLEController) {
        bleController.startWiFiOnly()
    }
}
