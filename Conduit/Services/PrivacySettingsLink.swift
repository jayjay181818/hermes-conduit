import UIKit

/// Where an "Open Settings" button goes after a permission was refused:
/// Conduit's page in iPhone Settings, or on the Mac build
/// (scripts/mac-catalyst-build.sh) the System Settings privacy pane for
/// that permission, where a Mac lists the apps allowed it.
enum PrivacySettingsLink {
    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case speechRecognition = "Privacy_SpeechRecognition"
        case location = "Privacy_LocationServices"
        case camera = "Privacy_Camera"
    }

    static func url(for pane: Pane) -> URL? {
        #if targetEnvironment(macCatalyst)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }

    static func open(_ pane: Pane) {
        guard let url = url(for: pane) else { return }
        UIApplication.shared.open(url)
    }
}
