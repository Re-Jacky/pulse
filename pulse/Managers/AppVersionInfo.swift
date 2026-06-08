import Foundation

struct AppVersionInfo {
    let appVersion: String?
    let operatingSystemVersion: OperatingSystemVersion

    init(
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.appVersion = appVersion
        self.operatingSystemVersion = operatingSystemVersion
    }

    var appDisplayVersion: String {
        guard let appVersion, appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return "Pulse"
        }

        return "Pulse \(appVersion)"
    }

    var systemDisplayVersion: String {
        "macOS \(operatingSystemVersion.majorVersion).\(operatingSystemVersion.minorVersion)"
    }
}
