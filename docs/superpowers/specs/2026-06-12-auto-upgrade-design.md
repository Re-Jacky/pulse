# Auto Upgrade Design

**Date:** 2026-06-12
**Status:** Ready for Review

## Goal

Add a near-automatic update flow for `Pulse` that:

- checks GitHub Releases for newer versions on app startup, throttled to once per 24 hours
- exposes a manual `Check for Updates...` entry in both Settings and the status item menu
- downloads the updater artifact inside `Pulse` with inline progress UI
- installs the update through a bundled helper after explicit user confirmation
- relaunches the updated app automatically on success
- falls back to recovery instructions only when install or relaunch fails

The design must fit the project's current distribution model: an unsigned internal app distributed outside the App Store.

## Existing Context

- `Pulse` is a macOS menu bar app using AppKit plus SwiftUI, with `AppDelegate` owning top-level windows and shared managers.
- The current release packaging script builds a DMG via `scripts/build-dmg.sh`.
- The project intentionally has no existing auto-update mechanism.
- Users currently may need to remove quarantine manually after installation with:

```bash
xattr -dr com.apple.quarantine /Applications/Pulse.app
```

- The app should remain lightweight in normal use and should not show a separate updater window during download.

## Constraints

- No App Store distribution.
- No external dependencies.
- The app remains unsigned and intended for personal or internal use.
- The normal update path should avoid asking users to rerun the `xattr` command.
- The updater window should appear only during the install and relaunch phase, not during update checks or download progress.

## Chosen Approach

Use a two-part update system:

1. An in-app `UpdateManager` inside `Pulse`
2. A bundled `PulseUpdater` helper executable launched only for install, swap, relaunch, and recovery

Release publishing should provide two assets:

1. A DMG for normal manual installs
2. A ZIP containing `Pulse.app` for the updater path

`Pulse` uses the ZIP artifact for in-app updates. This avoids mounting a DMG in the automated path and keeps staging and replacement logic simpler.

## Alternatives Considered

### 1. Update notification only, no download or install support

Rejected because it does not meet the goal of a near-automatic upgrade flow and still leaves the user doing most of the work.

### 2. In-app download followed by manual app replacement

Rejected as the primary design because it improves convenience but still leaves a clumsy final install path. It remains a useful fallback model if helper-based install proves too fragile in practice.

### 3. Fully silent self-replacement without a helper or rollback

Rejected because replacing a running app directly is too risky. For an unsigned app, this would be the easiest way to leave the user with a broken or missing installation.

## Architecture

### UpdateManager

Add an `UpdateManager` shared object created once in `AppDelegate` and injected into SwiftUI similarly to the existing managers.

Responsibilities:

- decide when startup checks should run
- fetch and parse the latest GitHub release metadata
- compare the current app version against the latest release
- publish update state for the status item menu and Settings UI
- download the updater ZIP asset
- report inline download progress
- verify the staged artifact before install handoff
- launch the bundled updater helper with the required arguments

`UpdateManager` should own the update state machine and any persisted metadata such as the last successful check timestamp.

### PulseUpdater helper

Bundle a small helper executable inside `Pulse.app`.

Responsibilities:

- show a minimal install-only window
- wait for `Pulse` to exit
- move the current installed app to a backup path
- move the staged new app into `/Applications/Pulse.app`
- clear quarantine on the installed app as a best-effort step
- relaunch the new app
- wait for a launch success signal
- restore the backup and present recovery UI if install or relaunch fails

The helper should stay intentionally narrow. Downloading and release lookup remain inside `Pulse`.

## Release Artifact Strategy

GitHub Releases should publish:

- `Pulse-<version>.dmg` for manual installs
- `Pulse-<version>-updater.zip` or equivalent ZIP artifact for the automated updater

The updater ZIP should expand directly to a `Pulse.app` bundle.

The app updater path should not consume the DMG because:

- ZIP is simpler to unpack in a temp directory
- ZIP avoids DMG mount lifecycle complexity
- the install helper only needs an app bundle, not an end-user installer image

## Update Check Behavior

### Automatic checks

On app startup, `UpdateManager` should check for updates only if the last successful check was more than 24 hours ago.

This throttling should apply only to automatic startup checks. It should not block manual checks.

### Manual checks

Expose `Check for Updates...` in:

- the status item menu
- Settings

Manual checks should always run immediately regardless of the last automatic check time.

## UI Behavior

### Inside Pulse

Update UI appears in two places:

- Settings
- status item menu

The in-app states should be explicit:

- idle
- checking
- update available
- downloading
- ready to install
- install launching
- install failed
- up to date

The download experience should stay inside `Pulse`:

- use a download icon or action button when idle
- show inline progress once download starts
- enable `Install Update` only after verification succeeds

The updater window should not appear during download.

### Updater helper window

`PulseUpdater` should display a small AppKit install window only after the user chooses `Install Update`.

Normal content:

- `Installing Pulse <version>`
- spinner or progress indicator for install phase
- short status text such as `Preparing update`, `Replacing app`, or `Relaunching Pulse`

Failure content:

- short explanation of what failed
- button to reveal `/Applications`
- copyable recovery command

Recovery command:

```bash
xattr -dr com.apple.quarantine /Applications/Pulse.app
```

The recovery UI should appear only if install fails or the new app does not launch successfully.

## Update Flow

### 1. Check

`UpdateManager` calls GitHub Releases, preferably `releases/latest`, and extracts:

- version/tag
- release notes URL
- updater ZIP asset URL
- optional checksum metadata if published

The current app version should come from bundle metadata, not hard-coded values.

### 2. Download

When the user chooses to download the update, `Pulse` downloads the updater ZIP itself into a controlled temporary or application support location.

The download should avoid the browser path so the normal flow is less likely to reintroduce quarantine friction.

### 3. Verification

Before install handoff, `UpdateManager` should verify at least:

- the archive downloaded successfully and is readable
- the archive expands to a valid `Pulse.app`
- the bundle identifier matches the expected app
- the version matches the release metadata

If practical, the design should also support publishing and verifying a SHA-256 checksum alongside the ZIP artifact.

### 4. Install handoff

After verification:

- `Pulse` launches `PulseUpdater`
- passes the staged app path, install target path, expected version, and any state file path needed for relaunch confirmation
- `Pulse` transitions into install-launching state and exits

### 5. Swap and relaunch

`PulseUpdater` should:

- wait until the main app process has fully exited
- move the existing `/Applications/Pulse.app` to a backup location
- move the staged replacement app into `/Applications/Pulse.app`
- attempt to clear quarantine recursively on the newly installed app
- relaunch the app

The helper should never delete the previous installed copy before the replacement is fully staged and ready to move into place.

## Launch Success Detection

Install success must include launch success.

The helper should not treat the update as complete merely because the file move succeeded.

Use a relaunch success marker:

- on first launch after update, `Pulse` writes a small success marker in a known path or persisted app state
- `PulseUpdater` waits for that marker for a short timeout window
- if the marker appears, cleanup can proceed
- if the marker does not appear, the updater treats the update as failed

This is important because the installed app may still be blocked from launching by Gatekeeper or quarantine behavior even if the file replacement succeeded.

## Failure Handling And Recovery

### Download failure

- keep partial files isolated
- allow retry without corrupting prior staged content
- present a normal in-app error state, not updater UI

### Verification failure

- do not launch the updater helper
- discard the staged artifact if invalid
- show an in-app error state

### Install failure

If the helper cannot replace the app or encounters a filesystem error:

- restore the backup if replacement already started
- keep the old working installation if possible
- show updater recovery UI

### Relaunch failure

If the new app does not launch or does not publish the success marker in time:

- treat the update as failed
- keep or restore a rollback path if practical
- show updater recovery UI
- include the `xattr` recovery command

### Quarantine handling

The helper should proactively clear quarantine on the newly installed app as a best-effort step before relaunch.

This does not guarantee success, but it should reduce the number of cases where users need to run the recovery command manually.

## Security And Trust Model

Because the app is unsigned, the updater cannot rely on the same trust guarantees as signed and notarized apps.

This design should therefore include lightweight authenticity checks where practical:

- verify the expected bundle identifier
- verify the expected version
- verify a published checksum if available

This is still an internal-convenience updater, not a security-equivalent replacement for signed and notarized distribution.

## Data Persistence

Persist only the minimal update metadata needed for behavior and UX:

- last successful automatic check timestamp
- last known release version
- staged update metadata if needed to resume UI state
- relaunch success marker or pending-update marker

This data should remain minimal and local, consistent with the rest of the app.

## Proposed Types

The exact implementation can vary, but the design should roughly align with these concepts:

```swift
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(AppRelease)
    case downloading(AppRelease, progress: Double)
    case readyToInstall(AppRelease, stagedAppURL: URL)
    case launchingInstaller(AppRelease)
    case failed(String)
}

struct AppRelease: Equatable {
    let version: String
    let notesURL: URL?
    let zipAssetURL: URL
    let checksum: String?
}
```

The helper can use a small argument or file-based contract describing:

- staged app location
- install target path
- backup path
- expected version
- relaunch marker path

## Testing Strategy

Unit-level coverage should focus on logic that can be isolated:

- version comparison
- release metadata parsing
- update state transitions
- automatic check throttling
- verification logic for release metadata and bundle identity

Helper logic should be structured so install decisions and rollback behavior can be tested independently from UI where possible.

Manual verification should cover at least:

- no update available
- update available
- startup check throttling after a successful recent check
- manual check bypassing the throttle
- download progress UI in `Pulse`
- successful install and relaunch
- failed archive verification
- permission failure writing to `/Applications`
- relaunch blocked by security or quarantine behavior
- recovery UI showing the `xattr` command

## Non-Goals

- App Store update support
- code signing or notarization work
- a fully silent background updater with no user confirmation
- showing the updater helper during download
- automatic update install without an explicit `Install Update` action
- building a general-purpose package management system

## Verification

For implementation, verification should include:

- focused tests for update logic
- `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`

Because this feature adds a helper executable and filesystem replacement flow, manual end-to-end testing on a real machine is part of the required verification, not optional.
