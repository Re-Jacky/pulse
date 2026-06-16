# GitHub Manual Release Workflow Design

**Date:** 2026-06-16
**Status:** Proposed

## Goal

Add a GitHub Actions workflow that can be triggered manually from the Actions tab, builds Pulse using the existing release script, and publishes a GitHub Release with both generated artifacts.

## Scope

This design covers:

- manual dispatch only
- reading the release version from `MARKETING_VERSION` in `pulse.xcodeproj/project.pbxproj`
- building artifacts with `scripts/build-dmg.sh`
- publishing a GitHub Release automatically
- uploading both release artifacts:
  - `dist/Pulse-<version>.dmg`
  - `dist/Pulse-<version>-updater.zip`

This design does not cover:

- automatic releases on tag push
- automatic version bumping
- signing or notarization changes
- prerelease channels
- custom release notes generation beyond simple workflow-provided text

## Current State

- The repo has no existing `.github/workflows` directory.
- Release packaging already exists in `scripts/build-dmg.sh`.
- That script reads `MARKETING_VERSION` from `pulse.xcodeproj/project.pbxproj`.
- The script builds a Release app and emits both the DMG and updater ZIP into `dist/`.

## Chosen Approach

Use a single GitHub Actions workflow that wraps the existing `scripts/build-dmg.sh` script.

Why this approach:

- keeps local and CI release behavior aligned
- avoids duplicating packaging logic in YAML
- minimizes maintenance cost
- reduces the chance of release drift between local builds and GitHub builds

## Workflow Behavior

### Trigger

- `workflow_dispatch` only

### Runner

- `macos-latest`

### Permissions

- `contents: write`

This is required so the workflow can create a tag-backed GitHub Release and upload assets using the default `GITHUB_TOKEN`.

## Release Version Rules

- The workflow reads the version from `pulse.xcodeproj/project.pbxproj`
- It does not modify the version
- The release tag format is `v<version>`
- The release title format is `Pulse <version>`

Example:

- `MARKETING_VERSION = 1.8.3;`
- tag: `v1.8.3`
- title: `Pulse 1.8.3`

## Build Flow

The workflow will run these logical steps:

1. Check out the repository
2. Read `MARKETING_VERSION`
3. Fail if a release tag with that version already exists
4. Run `bash scripts/build-dmg.sh`
5. Verify expected files exist in `dist/`
6. Create and publish the GitHub Release
7. Upload both artifacts to the release

## Artifact Contract

The workflow depends on the current script output contract:

- `dist/Pulse-<version>.dmg`
- `dist/Pulse-<version>-updater.zip`

If either artifact is missing after the script completes, the workflow fails.

## Failure Handling

The workflow should fail without publishing a broken release in these cases:

- the project version cannot be read
- the version is empty
- the release tag already exists
- `scripts/build-dmg.sh` fails
- one or both expected artifacts are missing
- GitHub Release creation fails
- artifact upload fails

### Tag Collision Policy

If `v<version>` already exists, the workflow fails early.

Reasoning:

- prevents accidental overwrite of an existing release
- keeps release history predictable
- forces explicit version bumps before a new release

## Release Notes

For the first version of the workflow, release notes should stay simple.

Recommended behavior:

- set a short body such as `Automated release for Pulse <version>.`

This keeps the workflow deterministic and avoids adding changelog-generation logic before it is needed.

## Security Model

- use the built-in `GITHUB_TOKEN`
- do not require personal access tokens
- restrict permissions to what the workflow needs: `contents: write`

No secrets beyond GitHub’s default token are required for this first version.

## Operational Constraints

- The workflow assumes GitHub-hosted macOS runners can build the app with the current Xcode/macOS image.
- The workflow does not attempt notarization, stapling, or Developer ID signing.
- Resulting artifacts are suitable for the project’s current release flow, not for a notarized distribution pipeline.

## File Changes

### New files

- `.github/workflows/release.yml`

### Existing files reused

- `scripts/build-dmg.sh`
- `pulse.xcodeproj/project.pbxproj`

No changes are required to release packaging logic for the first workflow version unless implementation uncovers runner-specific path or casing issues.

## Testing Strategy

### Local validation

Before relying on the workflow:

- confirm `bash scripts/build-dmg.sh` works locally
- confirm the output filenames match the workflow expectations

### Workflow validation

Initial validation should confirm:

- manual dispatch appears in the Actions tab
- workflow reads the correct version
- workflow builds successfully on `macos-latest`
- workflow publishes `v<version>`
- workflow uploads both the DMG and updater ZIP

### Negative-path validation

After first success, confirm expected failure behavior for:

- rerunning without changing version
- missing artifact path
- build failure

## Open Questions

None for the first version. The requested behavior is specific enough to implement directly.

## Future Extensions

If needed later, this design can be extended with:

- automatic trigger on tag push
- draft releases instead of immediate publish
- prerelease support
- generated release notes
- notarization/signing pipeline
- checksum generation
- artifact retention in workflow summaries
