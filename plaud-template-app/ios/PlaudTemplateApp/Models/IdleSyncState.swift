import Foundation

/// Result of a per-network "Sync when idle" connectivity test.
enum IdleSyncTestStatus: Equatable {
    case untested
    case testing
    case passed
    case failed
}

/// One WiFi network configured on the device for idle/charging auto-sync.
/// `index` is the device-side slot identifier returned by `getWifiSyncList()`.
struct IdleSyncNetwork: Equatable {
    let index: UInt32
    var ssid: String
    var hasPassword: Bool
    var testStatus: IdleSyncTestStatus = .untested
}

/// Snapshot of the device's "Sync when idle" configuration.
/// The device is the source of truth — this is rebuilt from SDK callbacks.
struct IdleSyncState: Equatable {
    var enabled: Bool = false
    var networks: [IdleSyncNetwork] = []
    var lastError: String?
}
