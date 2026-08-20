import Combine
import Foundation
import IOKit.pwr_mgt

@MainActor
final class KeepAwakeSettings: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable, Codable {
        case smart, manual
        var id: String { rawValue }
        var label: String {
            switch self {
            case .smart: return "Smart"
            case .manual: return "Manual"
            }
        }
    }

    enum TimerDuration: String, CaseIterable, Identifiable, Codable {
        case indefinite, m30, h1, h2, h5
        var id: String { rawValue }
        var label: String {
            switch self {
            case .indefinite: return "Indefinite"
            case .m30: return "30 min"
            case .h1: return "1 hr"
            case .h2: return "2 hr"
            case .h5: return "5 hr"
            }
        }
        var interval: TimeInterval? {
            switch self {
            case .indefinite: return nil
            case .m30: return 30 * 60
            case .h1: return 60 * 60
            case .h2: return 2 * 60 * 60
            case .h5: return 5 * 60 * 60
            }
        }
    }

    private enum Keys {
        static let mode = "general.keepAwake.mode"
        static let displaySleepOnly = "general.keepAwake.displaySleepOnly"
        static let timerDuration = "general.keepAwake.timerDuration"
        static let isActive = "general.keepAwake.isActive"
        static let timerEndDate = "general.keepAwake.timerEndDate"
    }

    @Published var mode: Mode {
        didSet {
            userDefaults.set(mode.rawValue, forKey: Keys.mode)
            apply()
        }
    }

    @Published var displaySleepOnly: Bool {
        didSet {
            userDefaults.set(displaySleepOnly, forKey: Keys.displaySleepOnly)
            if isActive {
                releaseAssertion()
                createAssertion()
            }
        }
    }

    @Published var timerDuration: TimerDuration {
        didSet {
            userDefaults.set(timerDuration.rawValue, forKey: Keys.timerDuration)
            if isActive {
                cancelTimer()
                scheduleTimerIfNeeded()
            }
        }
    }

    @Published private(set) var isActive: Bool {
        didSet {
            userDefaults.set(isActive, forKey: Keys.isActive)
            onIsActiveChange?(isActive)
        }
    }

    var isSmartAvailable: Bool {
        agentLightsEnabled() && installedAgentCheck()
    }

    var onIsActiveChange: ((Bool) -> Void)?

    private let userDefaults: UserDefaults
    private let agentLightsEnabled: () -> Bool
    private let installedAgentCheck: () -> Bool

    private var assertionID: IOPMAssertionID = 0
    private var timerWorkItem: DispatchWorkItem?

    init(
        userDefaults: UserDefaults = .standard,
        agentLightsEnabled: @escaping () -> Bool = { false },
        hasInstalledAgent: @escaping () -> Bool = { false }
    ) {
        self.userDefaults = userDefaults
        self.agentLightsEnabled = agentLightsEnabled
        self.installedAgentCheck = hasInstalledAgent

        let savedMode = Mode(rawValue: userDefaults.string(forKey: Keys.mode) ?? "") ?? .manual
        self.mode = savedMode
        self.displaySleepOnly = userDefaults.bool(forKey: Keys.displaySleepOnly)
        let savedDuration = TimerDuration(rawValue: userDefaults.string(forKey: Keys.timerDuration) ?? "") ?? .indefinite
        self.timerDuration = savedDuration
        self.isActive = userDefaults.bool(forKey: Keys.isActive)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            activate()
        } else {
            deactivate()
        }
    }

    func restoreIfNeeded() {
        guard isActive else { return }
        if mode == .manual {
            createAssertion()
            scheduleTimerIfNeeded()
        }
    }

    func deactivate() {
        cancelTimer()
        releaseAssertion()
        isActive = false
    }

    // MARK: - Private

    private func apply() {
        if isActive {
            releaseAssertion()
            if mode == .manual {
                createAssertion()
                cancelTimer()
                scheduleTimerIfNeeded()
            }
        }
    }

    private func activate() {
        cancelTimer()
        releaseAssertion()
        userDefaults.set(mode.rawValue, forKey: Keys.mode)
        createAssertion()
        isActive = true
        scheduleTimerIfNeeded()
    }

    private func createAssertion() {
        let type: String
        if displaySleepOnly {
            type = kIOPMAssertionTypePreventUserIdleSystemSleep as String
        } else {
            type = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        }

        let reason = "Pulse Keep Awake" as CFString
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result != kIOReturnSuccess {
            assertionID = 0
        }
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    private func scheduleTimerIfNeeded() {
        guard let interval = timerDuration.interval else { return }
        let endDate = Date().addingTimeInterval(interval)
        userDefaults.set(endDate.timeIntervalSince1970, forKey: Keys.timerEndDate)

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.deactivate()
            }
        }
        timerWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func cancelTimer() {
        timerWorkItem?.cancel()
        timerWorkItem = nil
        userDefaults.removeObject(forKey: Keys.timerEndDate)
    }
}
