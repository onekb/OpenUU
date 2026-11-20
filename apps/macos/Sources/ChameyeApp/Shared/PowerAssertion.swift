import Foundation
import IOKit.pwr_mgt

/// Prevents macOS display sleep and idle system sleep using IOKit power assertions (like `caffeinate -d`).
final class SleepPreventer: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0
    private var isActive = false

    func setEnabled(_ enabled: Bool) {
        if enabled == isActive { return }
        if enabled {
            let reason = "Chameye Host 正在共享远程窗口" as CFString
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &assertionID
            )
            isActive = (status == kIOReturnSuccess)
        } else {
            if isActive {
                IOPMAssertionRelease(assertionID)
                assertionID = 0
                isActive = false
            }
        }
    }

    deinit {
        if isActive {
            IOPMAssertionRelease(assertionID)
        }
    }
}
