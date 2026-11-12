import UIKit

extension ProcessInfo {
    /// Conduit is running on a Mac: the iPad app on Apple silicon
    /// (`isiOSAppOnMac`) or the Mac Catalyst build
    /// (scripts/mac-catalyst-build.sh), where `isiOSAppOnMac` is false.
    /// Both draw with UIKit on macOS, with a pointer and a keyboard.
    var runsOnMac: Bool {
        isiOSAppOnMac || isMacCatalystApp
    }
}

extension UIDevice {
    /// The device name Conduit gives Hermes. Without a special entitlement
    /// iOS says only "iPhone" or "iPad", and on a Mac it says "iPad": there
    /// it is "Mac".
    var conduitName: String {
        guard ProcessInfo.processInfo.runsOnMac, name.isEmpty || name == "iPad" || name == "iPhone" else { return name }
        return "Mac"
    }
}
