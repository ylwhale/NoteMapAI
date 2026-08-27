import Foundation

/// Keys used by `Settings.bundle` and the app's launch-tracking logic.
enum SettingsKeys {
    static let developerName = "developer_name"
    static let showOnboarding = "show_onboarding"

    /// Required by the final project rubric: store an NSDate on first launch.
    static let initialLaunchDate = "Initial Launch"

    /// Used to trigger the "Rate this App" prompt on the 3rd launch.
    static let launchCount = "launch_count"
    static let didPromptRate = "did_prompt_rate"
    static let pendingRatePrompt = "pending_rate_prompt"

    /// Convenience: surfaced in Settings.bundle as a read-only value.
    static let appVersion = "app_version"
}

/// Manages Settings.bundle defaults and launch-tracking required by the final-project rubric.
enum SettingsManager {

    /// Register reasonable defaults so Settings.bundle values always have a value.
    static func registerDefaults() {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        UserDefaults.standard.register(defaults: [
            SettingsKeys.developerName: "Jingyu Huang",
            SettingsKeys.showOnboarding: true,
            SettingsKeys.launchCount: 0,
            SettingsKeys.didPromptRate: false,
            SettingsKeys.pendingRatePrompt: false,
            SettingsKeys.appVersion: version,
            "ra_mapIsSatellite": false
        ])
        AppLog.info("SettingsManager.registerDefaults: version=\(version)")
    }

    /// Call once per launch. Increments launch count and sets the initial-launch timestamp.
    static func handleLaunch() {
        let defaults = UserDefaults.standard

        // Required: store an NSDate on first launch.
        if defaults.object(forKey: SettingsKeys.initialLaunchDate) == nil {
            let now = Date()
            defaults.set(now, forKey: SettingsKeys.initialLaunchDate)
            AppLog.info("Initial Launch date set: \(now)")
        } else if let date = defaults.object(forKey: SettingsKeys.initialLaunchDate) as? Date {
            AppLog.info("Initial Launch date (existing): \(date)")
        }

        let previousCount = defaults.integer(forKey: SettingsKeys.launchCount)
        let newCount = previousCount + 1
        defaults.set(newCount, forKey: SettingsKeys.launchCount)
        AppLog.info("Launch count updated: \(previousCount) -> \(newCount)")

        // Required: prompt to "Rate this App" on the 3rd launch (custom alert).
        let alreadyPrompted = defaults.bool(forKey: SettingsKeys.didPromptRate)
        if newCount == 3 && !alreadyPrompted {
            defaults.set(true, forKey: SettingsKeys.pendingRatePrompt)
            AppLog.info("Rate prompt scheduled for this launch (launchCount=3)")
        }
    }

    /// Returns true if the app should show the "Rate this App" alert right now (and consumes the flag).
    static func consumePendingRatePrompt() -> Bool {
        let defaults = UserDefaults.standard
        let pending = defaults.bool(forKey: SettingsKeys.pendingRatePrompt)
        if pending {
            defaults.set(false, forKey: SettingsKeys.pendingRatePrompt)
        }
        return pending
    }

    /// Mark the rate prompt as shown (so it won't repeat on later launches).
    static func markRatePromptShown(userAction: String) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: SettingsKeys.didPromptRate)
        defaults.set(false, forKey: SettingsKeys.pendingRatePrompt)
        AppLog.action("Rate prompt dismissed: \(userAction)")
    }
}
