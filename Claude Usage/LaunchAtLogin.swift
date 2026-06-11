import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Logged and swallowed: the toggle may briefly diverge from the
            // real status until the popover reopens and re-reads isEnabled.
            NSLog("LaunchAtLogin: \(error.localizedDescription)")
        }
    }
}
