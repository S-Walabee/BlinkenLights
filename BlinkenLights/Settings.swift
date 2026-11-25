import Foundation
import Observation
import ServiceManagement

/// User preferences, persisted in UserDefaults.
@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    /// Available update intervals, in seconds.
    static let intervals: [Double] = [0.1, 0.25, 0.5, 1.0, 2.0]

    @ObservationIgnored private let defaults = UserDefaults.standard

    var isVertical: Bool { didSet { defaults.set(isVertical, forKey: "isVertical") } }
    var alwaysVisible: Bool { didSet { defaults.set(alwaysVisible, forKey: "alwaysVisible") } }
    /// Background opacity, 0 (fully transparent) ... 1 (opaque).
    var backgroundOpacity: Double { didSet { defaults.set(backgroundOpacity, forKey: "backgroundOpacity") } }
    var updateInterval: Double { didSet { defaults.set(updateInterval, forKey: "updateInterval") } }
    /// Show each volume's free space as a percentage beside its name.
    var showFreeSpace: Bool { didSet { defaults.set(showFreeSpace, forKey: "showFreeSpace") } }

    private init() {
        defaults.register(defaults: [
            "isVertical": true,
            "alwaysVisible": true,
            "backgroundOpacity": 0.75,
            "updateInterval": 0.5,
            "showFreeSpace": true,
        ])
        isVertical = defaults.bool(forKey: "isVertical")
        alwaysVisible = defaults.bool(forKey: "alwaysVisible")
        backgroundOpacity = defaults.double(forKey: "backgroundOpacity")
        updateInterval = defaults.double(forKey: "updateInterval")
        showFreeSpace = defaults.bool(forKey: "showFreeSpace")
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("BlinkenLights: launch-at-login change failed: \(error)")
        }
    }

    /// Turns launch-at-login on the first time the app runs.
    func applyFirstRunDefaults() {
        if !defaults.bool(forKey: "didInitLaunchAtLogin") {
            defaults.set(true, forKey: "didInitLaunchAtLogin")
            setLaunchAtLogin(true)
        }
    }
}
