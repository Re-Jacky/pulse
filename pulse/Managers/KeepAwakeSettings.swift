import Combine
import Foundation
import IOKit.pwr_mgt
import os

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

    @Published private(set) var mode: Mode {
        didSet {
            userDefaults.set(mode.rawValue, forKey: Keys.mode)
            if mode != .smart {
                stopSmartMonitoring()
            }
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

    private let logger = Logger(subsystem: "com.example.pulse", category: "KeepAwake")
    private var assertionID: IOPMAssertionID = 0
    private var timerWorkItem: DispatchWorkItem?
    private let idleCooldown: TimeInterval = 300
    private var smartIdleWorkItem: DispatchWorkItem?
    private var groupsObservation: AnyCancellable?
    private var isSmartAsserted = false

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

    func setMode(_ newMode: Mode) {
        if newMode == .smart && !isSmartAvailable {
            mode = .manual
        } else {
            mode = newMode
        }
    }

    func restoreIfNeeded() {
        guard isActive else { return }
        if mode == .manual {
            createAssertion()
            if let storedEndTimestamp = userDefaults.object(forKey: Keys.timerEndDate) as? TimeInterval {
                let remaining = storedEndTimestamp - Date().timeIntervalSince1970
                if remaining > 0 {
                    scheduleTimer(with: remaining)
                } else {
                    deactivate()
                }
            } else {
                scheduleTimerIfNeeded()
            }
        } else if mode == .smart {
            if !isSmartAvailable {
                deactivate()
                return
            }
            // Smart mode: observation will be started by AppDelegate
        }
    }

    func deactivate() {
        cancelTimer()
        stopSmartMonitoring()
        releaseAssertion()
        isSmartAsserted = false
        isActive = false
        logger.info("KeepAwake deactivated")
    }

    // MARK: - Smart Mode

    func startSmartMonitoring(store: AgentStatusStore) {
        stopSmartMonitoring()
        groupsObservation = store.$groups
            .receive(on: RunLoop.main)
            .sink { [weak self] groups in
                self?.handleAgentGroups(groups)
            }
    }

    func stopSmartMonitoring() {
        groupsObservation?.cancel()
        groupsObservation = nil
        smartIdleWorkItem?.cancel()
        smartIdleWorkItem = nil
        if isSmartAsserted {
            releaseAssertion()
            isSmartAsserted = false
        }
    }

    private func handleAgentGroups(_ groups: [AgentStatusGroup]) {
        guard mode == .smart else { return }

        let hasWorking = groups.flatMap(\.slots).contains { $0.state == .working }

        if hasWorking {
            smartIdleWorkItem?.cancel()
            smartIdleWorkItem = nil

            if !isSmartAsserted {
                createAssertion()
                isSmartAsserted = true
                isActive = true
                logger.info("Smart mode: assertion created (agent working)")
            }
        } else if isSmartAsserted {
            if smartIdleWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        self?.releaseAssertion()
                        self?.isSmartAsserted = false
                        self?.isActive = false
                        self?.smartIdleWorkItem = nil
                        self?.logger.info("Smart mode: assertion released (agents idle)")
                    }
                }
                smartIdleWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + idleCooldown, execute: work)
                logger.info("Smart mode: idle timer started (5 min cooldown)")
            }
        }
    }

    // MARK: - Private

    private func apply() {
        if isActive {
            releaseAssertion()
            if mode == .smart {
                if !isSmartAvailable {
                    mode = .manual
                    return
                }
            } else {
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
        logger.info("KeepAwake activated (mode: \(self.mode.rawValue))")
    }

    private func createAssertion() {
        let type: String
        if displaySleepOnly {
            type = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        } else {
            type = kIOPMAssertionTypePreventUserIdleSystemSleep as String
        }

        let reason = "Pulse Keep Awake" as CFString
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result != kIOReturnSuccess {
            logger.error("IOPMAssertionCreateWithName failed: \(result)")
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
        scheduleTimer(with: interval)
        logger.info("Timer scheduled for \(self.timerDuration.label)")
    }

    private func scheduleTimer(with remaining: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.deactivate()
            }
        }
        timerWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func cancelTimer() {
        timerWorkItem?.cancel()
        timerWorkItem = nil
        userDefaults.removeObject(forKey: Keys.timerEndDate)
    }
}
