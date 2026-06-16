# GitHub Manual Release Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a manual GitHub Actions workflow that builds Pulse with the existing release script and publishes a GitHub Release with both release artifacts.

**Architecture:** The workflow will be a single `workflow_dispatch` GitHub Actions job running on `macos-latest`. It will read `MARKETING_VERSION` from `pulse.xcodeproj/project.pbxproj`, fail early if the `v<version>` tag already exists, call `scripts/build-dmg.sh`, verify the expected DMG and updater ZIP outputs, then create and publish a GitHub Release using the built-in `GITHUB_TOKEN`.

**Tech Stack:** GitHub Actions YAML, macOS runner shell, existing `bash` release script, GitHub CLI (`gh`)

---

### File Structure

**New file responsibilities**

- `.github/workflows/release.yml`
  - Owns the manual release workflow only
  - Reads the app version
  - Checks release tag collisions
  - Builds artifacts via `scripts/build-dmg.sh`
  - Verifies the expected artifact paths exist
  - Creates and publishes the GitHub Release

**Existing files reused**

- `scripts/build-dmg.sh`
  - Remains the single source of truth for building release artifacts
- `pulse.xcodeproj/project.pbxproj`
  - Remains the source of `MARKETING_VERSION`

No packaging logic should be duplicated into a second shell script. Keep release assembly centralized in `scripts/build-dmg.sh`.

---

### Task 1: Add the manual release workflow skeleton

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Write the failing workflow file with manual trigger and permissions**

Create `.github/workflows/release.yml` with this initial content:

```yaml
name: Release

on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-latest

    steps:
      - name: Check out repository
        uses: actions/checkout@v4
```

- [ ] **Step 2: Verify the workflow file is present**

Run: `ls .github/workflows`
Expected: `release.yml`

- [ ] **Step 3: Commit the workflow skeleton**

```bash
git add .github/workflows/release.yml
git commit -m "feat(ci): add manual release workflow skeleton"
```

---

### Task 2: Read and validate the release version

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Add a version extraction step**

Update `.github/workflows/release.yml` so the job contains these steps after checkout:

```yaml
      - name: Read release version
        id: version
        shell: bash
        run: |
          VERSION=$(grep -m1 'MARKETING_VERSION' pulse.xcodeproj/project.pbxproj | sed 's/.*= *//;s/;//')

          if [ -z "${VERSION}" ]; then
            echo "Failed to read MARKETING_VERSION" >&2
            exit 1
          fi

          echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
          echo "tag=v${VERSION}" >> "$GITHUB_OUTPUT"
          echo "dmg=dist/Pulse-${VERSION}.dmg" >> "$GITHUB_OUTPUT"
          echo "zip=dist/Pulse-${VERSION}-updater.zip" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Add a step that prints the resolved values for debugging**

Append this step after the version step:

```yaml
      - name: Show resolved release values
        shell: bash
        run: |
          echo "Version: ${{ steps.version.outputs.version }}"
          echo "Tag: ${{ steps.version.outputs.tag }}"
          echo "DMG: ${{ steps.version.outputs.dmg }}"
          echo "ZIP: ${{ steps.version.outputs.zip }}"
```

- [ ] **Step 3: Verify the version source in the project file**

Run: `grep -m1 'MARKETING_VERSION' pulse.xcodeproj/project.pbxproj`
Expected: a line containing `MARKETING_VERSION = 1.8.3;` or the current release version

- [ ] **Step 4: Commit the version extraction logic**

```bash
git add .github/workflows/release.yml
git commit -m "feat(ci): read release version from project settings"
```

---

### Task 3: Fail early if the release tag already exists

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Add a tag collision check step**

Insert this step after `Show resolved release values`:

```yaml
      - name: Fail if release tag already exists
        shell: bash
        run: |
          if git ls-remote --exit-code --tags origin "refs/tags/${{ steps.version.outputs.tag }}" >/dev/null 2>&1; then
            echo "Tag ${{ steps.version.outputs.tag }} already exists" >&2
            exit 1
          fi
```

- [ ] **Step 2: Verify the command format locally**

Run: `git ls-remote --tags origin "refs/tags/v0.0.0-does-not-exist"`
Expected: no matching output and a non-zero exit code

- [ ] **Step 3: Commit the tag guard**

```bash
git add .github/workflows/release.yml
git commit -m "feat(ci): fail release workflow when tag already exists"
```

---

### Task 4: Build artifacts and verify the expected outputs

**Files:**
- Modify: `.github/workflows/release.yml`
- Reuse: `scripts/build-dmg.sh`

- [ ] **Step 1: Add the build step that calls the existing script**

Append this step after the tag collision check:

```yaml
      - name: Build release artifacts
        shell: bash
        run: bash scripts/build-dmg.sh
```

- [ ] **Step 2: Add explicit artifact verification**

Append this step after `Build release artifacts`:

```yaml
      - name: Verify release artifacts exist
        shell: bash
        run: |
          if [ ! -f "${{ steps.version.outputs.dmg }}" ]; then
            echo "Missing DMG artifact: ${{ steps.version.outputs.dmg }}" >&2
            exit 1
          fi

          if [ ! -f "${{ steps.version.outputs.zip }}" ]; then
            echo "Missing updater ZIP artifact: ${{ steps.version.outputs.zip }}" >&2
            exit 1
          fi

          ls -lh "${{ steps.version.outputs.dmg }}" "${{ steps.version.outputs.zip }}"
```

- [ ] **Step 3: Validate the release script locally before relying on CI**

Run: `bash scripts/build-dmg.sh`
Expected: output ending with `==> Done: dist/Pulse-<version>-updater.zip dist/Pulse-<version>.dmg`

- [ ] **Step 4: Verify the artifact filenames match the workflow contract**

Run: `ls dist`
Expected: both `Pulse-<version>.dmg` and `Pulse-<version>-updater.zip`

- [ ] **Step 5: Commit the build and verification steps**

```bash
git add .github/workflows/release.yml
git commit -m "feat(ci): build and verify release artifacts in workflow"
```

---

### Task 5: Create and publish the GitHub Release

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Add the GitHub Release creation step**

Append this step after `Verify release artifacts exist`:

```yaml
      - name: Create GitHub Release
        env:
          GITHUB_TOKEN: ${{ github.token }}
        shell: bash
        run: |
          gh release create "${{ steps.version.outputs.tag }}" \
            "${{ steps.version.outputs.dmg }}" \
            "${{ steps.version.outputs.zip }}" \
            --repo "${{ github.repository }}" \
            --title "Pulse ${{ steps.version.outputs.version }}" \
            --notes "Automated release for Pulse ${{ steps.version.outputs.version }}"
```

- [ ] **Step 2: Add a release summary step for workflow logs**

Append this step after `Create GitHub Release`:

```yaml
      - name: Write workflow summary
        shell: bash
        run: |
          {
            echo "## Release Published"
            echo ""
            echo "- Version: ${{ steps.version.outputs.version }}"
            echo "- Tag: ${{ steps.version.outputs.tag }}"
            echo "- DMG: ${{ steps.version.outputs.dmg }}"
            echo "- ZIP: ${{ steps.version.outputs.zip }}"
          } >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 3: Review the full workflow file for a single coherent flow**

Run: `sed -n '1,220p' .github/workflows/release.yml`
Expected: one `Release` workflow with checkout, version read, tag check, build, artifact verification, release creation, and summary steps in that order

- [ ] **Step 4: Commit the release publishing step**

```bash
git add .github/workflows/release.yml
git commit -m "feat(ci): publish GitHub Release from manual workflow"
```

---

### Task 6: Update documentation for maintainers

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a GitHub release workflow section to the README**

Insert this section after the DMG build instructions and before `## Running`:

```md
## GitHub Release Workflow

The repository includes a manual GitHub Actions release workflow.

To publish a release:

1. Bump `MARKETING_VERSION` in `pulse.xcodeproj/project.pbxproj`
2. Push the change to GitHub
3. Open the **Actions** tab
4. Run the **Release** workflow manually

The workflow will:

- read the current `MARKETING_VERSION`
- build the app with `bash scripts/build-dmg.sh`
- create a GitHub Release tagged `v<version>`
- upload:
  - `Pulse-<version>.dmg`
  - `Pulse-<version>-updater.zip`

If the release tag already exists, the workflow fails and requires a new version bump.
```

- [ ] **Step 2: Verify the README still reads naturally**

Run: `grep -n "GitHub Release Workflow" README.md`
Expected: one matching section heading in the release/build part of the README

- [ ] **Step 3: Commit the README update**

```bash
git add README.md
git commit -m "docs: describe manual GitHub release workflow"
```

---

### Task 7: End-to-end verification

**Files:**
- Verify: `.github/workflows/release.yml`
- Verify: `README.md`
- Reuse: `scripts/build-dmg.sh`

- [ ] **Step 1: Build locally one more time**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Verify release packaging still works locally**

Run: `bash scripts/build-dmg.sh`
Expected: both release artifacts appear in `dist/`

- [ ] **Step 3: Inspect git status before final handoff**

Run: `git status --short`
Expected: clean working tree

- [ ] **Step 4: Push branch and run the workflow manually in GitHub**

Run:

```bash
git push origin main
```

Then in GitHub:

1. Open **Actions**
2. Select **Release**
3. Click **Run workflow**
4. Wait for the macOS job to finish

Expected:

- a new GitHub Release exists for `v<version>`
- release title is `Pulse <version>`
- assets include both the DMG and updater ZIP

- [ ] **Step 5: Negative-path verification for tag collision**

Run the same workflow again without bumping the version.

Expected: failure at `Fail if release tag already exists`

- [ ] **Step 6: Final commit if any verification-driven changes were needed**

If verification required changes:

```bash
git add .github/workflows/release.yml README.md
git commit -m "fix(ci): adjust manual release workflow after verification"
```

If verification required no changes, do not create an extra commit.
