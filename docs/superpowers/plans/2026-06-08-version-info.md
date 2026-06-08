# Version Info Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add product and macOS version info to the Overview panel and settings window, with shared formatting sourced from runtime bundle metadata.

**Architecture:** Introduce a tiny shared formatter/value helper that produces `Pulse <version>` and `macOS <major>.<minor>` strings. Reuse that helper from `OverviewView` and `SettingsView`, and keep the UI changes as small footer-style additions within the existing layouts.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Xcode project configuration

---

## File Map

- Create: `pulse/Managers/AppVersionInfo.swift`
  - Shared formatting helper for product and macOS version strings.
- Create: `pulseTests/AppVersionInfoTests.swift`
  - Unit tests for formatting and fallback behavior.
- Modify: `pulse/Views/OverviewView.swift`
  - Add compact version footer under the existing metric rows.
- Modify: `pulse/Views/SettingsView.swift`
  - Add matching version block in the settings detail pane.
- Modify: `pulse.xcodeproj/project.pbxproj`
  - Add the new Swift files to the app and test targets, add a new `pulseTests` target, and bump `MARKETING_VERSION` from `1.2.0` to `1.2.1` because this is a bug-free feature addition to already-versioned code under the repo's documented versioning rule.

## Notes Before Implementation

- This repo currently has no test target checked in, so TDD requires adding one first.
- The helper should avoid `ObservableObject`; the values are static for the process lifetime.
- Follow existing semantic color usage in SwiftUI views.
- After adding files on disk, update `project.pbxproj` so Xcode actually builds them.

### Task 1: Add a test target for TDD

**Files:**
- Modify: `pulse.xcodeproj/project.pbxproj`
- Create: `pulseTests/AppVersionInfoTests.swift`

- [ ] **Step 1: Add the failing test file skeleton**

Create `pulseTests/AppVersionInfoTests.swift` with this initial test content:

```swift
import XCTest
@testable import pulse

final class AppVersionInfoTests: XCTestCase {
    func testAppDisplayNameUsesBundleVersion() {
        let info = AppVersionInfo(appVersion: "1.2.1", operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0))

        XCTAssertEqual(info.appDisplayVersion, "Pulse 1.2.1")
    }
}
```

- [ ] **Step 2: Add a `pulseTests` target and test file references to the Xcode project**

Update `pulse.xcodeproj/project.pbxproj` to add a minimal unit test target named `pulseTests` that depends on `pulse`, includes `AppVersionInfoTests.swift` in its sources, and links the standard test product type. Also add the test file reference under a new `pulseTests` group.

Required project details to add:

```text
Product type: com.apple.product-type.bundle.unit-test
Test bundle name: pulseTests.xctest
Swift version: 5.0
Deployment target: 14.0
```

- [ ] **Step 3: Run the new test to verify RED**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AppVersionInfoTests/testAppDisplayNameUsesBundleVersion`

Expected: FAIL because `AppVersionInfo` does not exist yet.

- [ ] **Step 4: Commit the test-target scaffolding**

```bash
git add pulse.xcodeproj/project.pbxproj pulseTests/AppVersionInfoTests.swift
git commit -m "test: add version info test target"
```

### Task 2: Implement the shared version formatter with TDD

**Files:**
- Create: `pulse/Managers/AppVersionInfo.swift`
- Modify: `pulseTests/AppVersionInfoTests.swift`
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Expand the failing tests for all required formatting behavior**

Update `pulseTests/AppVersionInfoTests.swift` to cover the agreed scope:

```swift
import XCTest
@testable import pulse

final class AppVersionInfoTests: XCTestCase {
    func testAppDisplayNameUsesBundleVersion() {
        let info = AppVersionInfo(appVersion: "1.2.1", operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0))

        XCTAssertEqual(info.appDisplayVersion, "Pulse 1.2.1")
    }

    func testAppDisplayNameFallsBackWhenVersionMissing() {
        let info = AppVersionInfo(appVersion: nil, operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0))

        XCTAssertEqual(info.appDisplayVersion, "Pulse")
    }

    func testAppDisplayNameFallsBackWhenVersionBlank() {
        let info = AppVersionInfo(appVersion: "   ", operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0))

        XCTAssertEqual(info.appDisplayVersion, "Pulse")
    }

    func testSystemDisplayVersionUsesMajorAndMinor() {
        let info = AppVersionInfo(appVersion: "1.2.1", operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 1))

        XCTAssertEqual(info.systemDisplayVersion, "macOS 15.0")
    }
}
```

- [ ] **Step 2: Run the formatter tests to verify RED**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AppVersionInfoTests`

Expected: FAIL because `AppVersionInfo` and its properties are still undefined.

- [ ] **Step 3: Add the minimal implementation and source file project entry**

Create `pulse/Managers/AppVersionInfo.swift` with this code:

```swift
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
        guard let appVersion, !appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Pulse"
        }

        return "Pulse \(appVersion)"
    }

    var systemDisplayVersion: String {
        "macOS \(operatingSystemVersion.majorVersion).\(operatingSystemVersion.minorVersion)"
    }
}
```

Also add `AppVersionInfo.swift` to the `Managers` group and the app target's `Sources` build phase in `pulse.xcodeproj/project.pbxproj`.

- [ ] **Step 4: Run the formatter tests to verify GREEN**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AppVersionInfoTests`

Expected: PASS.

- [ ] **Step 5: Commit the formatter implementation**

```bash
git add pulse/Managers/AppVersionInfo.swift pulseTests/AppVersionInfoTests.swift pulse.xcodeproj/project.pbxproj
git commit -m "feat: add shared version info formatter"
```

### Task 3: Add version info to the Overview panel

**Files:**
- Modify: `pulse/Views/OverviewView.swift`
- Test: `pulseTests/AppVersionInfoTests.swift`

- [ ] **Step 1: Add a small view-level constant using the shared helper**

Update `pulse/Views/OverviewView.swift` to create a local static value or stored property near the top of the view:

```swift
private let versionInfo = AppVersionInfo()
```

If Swift requires this to be `private let versionInfo = AppVersionInfo()` directly inside the struct, use that form.

- [ ] **Step 2: Add the footer-style version section below the metric rows**

Update the `body` in `pulse/Views/OverviewView.swift` so the existing metrics remain intact and the footer is appended after them:

```swift
VStack(alignment: .leading, spacing: 18) {
    MetricRowView(
        label: "CPU",
        value: String(format: "%.0f%%", monitor.cpuUsage),
        subtext: "\(monitor.cpuCoreCount)-core · \(monitor.cpuChipName)",
        percent: monitor.cpuUsage,
        fillColors: cpuFillColors
    )

    MetricRowView(
        label: "MEM",
        value: String(format: "%.1f / %.0f GB", monitor.memUsedGB, monitor.memTotalGB),
        subtext: String(format: "%.1f GB used", monitor.memUsedGB),
        percent: monitor.memTotalGB > 0 ? (monitor.memUsedGB / monitor.memTotalGB) * 100 : 0,
        fillColors: [Color(hex: "#60a5fa"), Color(hex: "#818cf8")]
    )

    MetricRowView(
        label: "GPU",
        value: monitor.gpuUsage >= 0 ? String(format: "%.0f%%", monitor.gpuUsage) : "N/A",
        subtext: monitor.gpuCoreCount > 0 ? "\(monitor.gpuCoreCount)-core · \(monitor.gpuChipName)" : monitor.gpuChipName,
        percent: monitor.gpuUsage,
        fillColors: [Color(hex: "#f472b6"), Color(hex: "#e879f9")]
    )

    Divider()
        .background(Color.appDivider)
        .padding(.top, 2)

    VStack(alignment: .leading, spacing: 4) {
        Text(versionInfo.appDisplayVersion)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        Text(versionInfo.systemDisplayVersion)
            .font(.system(size: 12))
            .foregroundColor(.appSecondaryText)
    }
}
```

- [ ] **Step 3: Build to verify the Overview integration passes**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit the Overview UI change**

```bash
git add pulse/Views/OverviewView.swift
git commit -m "feat: show version info in overview"
```

### Task 4: Add version info to the settings window

**Files:**
- Modify: `pulse/Views/SettingsView.swift`

- [ ] **Step 1: Add a matching helper instance in the settings view**

Update `pulse/Views/SettingsView.swift` with a local property:

```swift
private let versionInfo = AppVersionInfo()
```

- [ ] **Step 2: Add the version block near the bottom of the detail pane**

Update the right-side `VStack` in `pulse/Views/SettingsView.swift` so the version info sits below the theme picker and above the final spacer behavior:

```swift
VStack(alignment: .leading, spacing: 14) {
    Text("Theme")
        .font(.system(size: 22, weight: .semibold))
        .foregroundColor(.appPrimaryText)

    Text("Choose whether Pulse follows the system appearance or always uses a specific theme.")
        .font(.system(size: 13))
        .foregroundColor(.appSecondaryText)
        .fixedSize(horizontal: false, vertical: true)

    Picker("Theme", selection: $themeManager.currentTheme) {
        ForEach(AppTheme.allCases, id: \.self) { theme in
            Text(theme.label).tag(theme)
        }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 320)

    Spacer()

    Divider()
        .background(Color.appDivider)

    VStack(alignment: .leading, spacing: 4) {
        Text(versionInfo.appDisplayVersion)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        Text(versionInfo.systemDisplayVersion)
            .font(.system(size: 12))
            .foregroundColor(.appSecondaryText)
    }
}
```

- [ ] **Step 3: Build to verify the settings integration passes**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit the settings UI change**

```bash
git add pulse/Views/SettingsView.swift
git commit -m "feat: show version info in settings"
```

### Task 5: Bump version and run final verification

**Files:**
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Bump `MARKETING_VERSION` from `1.2.0` to `1.3.0`**

Update both target build configurations in `pulse.xcodeproj/project.pbxproj`:

```pbxproj
MARKETING_VERSION = 1.3.0;
```

This is a feature addition, so the repo rule in `AGENTS.md` requires a minor version bump.

- [ ] **Step 2: Verify the version value**

Run: `grep -m1 'MARKETING_VERSION' pulse.xcodeproj/project.pbxproj`

Expected:

```text
MARKETING_VERSION = 1.3.0;
```

- [ ] **Step 3: Run the full formatter tests**

Run: `xcodebuild test -project pulse.xcodeproj -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/AppVersionInfoTests`

Expected: PASS.

- [ ] **Step 4: Run the required app build verification**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit the version bump and final verification state**

```bash
git add pulse.xcodeproj/project.pbxproj
git commit -m "feat: add app version info surfaces"
```

## Self-Review

- Spec coverage: the plan covers the shared runtime formatter, Overview footer placement, settings-window placement, `Pulse <version>` formatting, `macOS <major>.<minor>` formatting, fallback behavior, no build number, and required build verification.
- Placeholder scan: all tasks use exact files, explicit commands, and concrete code snippets; no `TODO`/`TBD` placeholders remain.
- Type consistency: the plan consistently uses `AppVersionInfo`, `appDisplayVersion`, and `systemDisplayVersion` across tests, implementation, and view integration.
