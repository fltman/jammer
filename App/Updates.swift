import AppKit
import Sparkle

/// Updates through Sparkle (MIT; the series' one exception to "no server of ours": the appcast on
/// jammer.brattoo.com). The feed's address and the public half of the EdDSA key that signs each update are
/// in Info.plist (SUFeedURL, SUPublicEDKey); the private half is in Anders's Keychain and never leaves it.
/// Debug builds and test copies never start the updater, so no test reaches the network and no question
/// about automatic checks comes up in a test.
@MainActor
final class Updates: NSObject {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    /// Only a release build checks for updates.
    static var enabled: Bool {
        #if DEBUG
        false
        #else
        Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil
        #endif
    }

    func start() {
        guard Self.enabled, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Jämmer › Check for Updates….
    @objc func checkForUpdates(_ sender: Any?) { controller?.checkForUpdates(sender) }
}

extension Updates: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(checkForUpdates(_:)) ? controller?.updater.canCheckForUpdates ?? false : true
    }
}
