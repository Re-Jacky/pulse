# Screenshot Corner Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable script that removes rounded-corner screenshot background bleed by making corner pixels transparent, then apply it to `docs/images/preview-agent.png`.

**Architecture:** Add one focused utility script under `scripts/` that operates in place on one or more PNG files. The script will load an image as RGBA, flood-fill from the four corners to detect connected outside-the-panel bleed pixels, and set those pixels' alpha channel to `0`, leaving the panel border and interior untouched.

**Tech Stack:** Python 3, Pillow, NumPy, existing repository shell/build workflow

---

### Task 1: Add the reusable screenshot cleanup script

**Files:**
- Create: `scripts/fix_screenshot_corners.py`
- Test: manual CLI run against `docs/images/preview-agent.png`

- [ ] **Step 1: Write the script file**

```python
#!/usr/bin/env python3

from __future__ import annotations

import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image


THRESHOLD = 70


def make_corners_transparent(path: Path) -> int:
    image = Image.open(path).convert("RGBA")
    pixels = np.array(image, dtype=np.uint8)
    height, width = pixels.shape[:2]

    visited = np.zeros((height, width), dtype=bool)
    queue: deque[tuple[int, int]] = deque()

    for row, col in ((0, 0), (0, width - 1), (height - 1, 0), (height - 1, width - 1)):
        if not visited[row, col]:
            visited[row, col] = True
            queue.append((row, col))

    while queue:
        row, col = queue.popleft()
        for delta_row, delta_col in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            next_row = row + delta_row
            next_col = col + delta_col
            if not (0 <= next_row < height and 0 <= next_col < width):
                continue
            if visited[next_row, next_col]:
                continue

            if int(pixels[next_row, next_col, :3].max()) < THRESHOLD:
                visited[next_row, next_col] = True
                queue.append((next_row, next_col))

    pixels[visited, 3] = 0
    Image.fromarray(pixels).save(path)
    return int(visited.sum())


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("Usage: scripts/fix_screenshot_corners.py <image.png> [more-images.png ...]", file=sys.stderr)
        return 1

    exit_code = 0
    for raw_path in argv[1:]:
        path = Path(raw_path)
        if not path.exists():
            print(f"error: file not found: {path}", file=sys.stderr)
            exit_code = 1
            continue
        if path.suffix.lower() != ".png":
            print(f"error: expected a .png file: {path}", file=sys.stderr)
            exit_code = 1
            continue

        try:
            changed = make_corners_transparent(path)
            print(f"fixed {path} ({changed} pixels made transparent)")
        except Exception as exc:
            print(f"error: failed to process {path}: {exc}", file=sys.stderr)
            exit_code = 1

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
```

- [ ] **Step 2: Run the script with no arguments to verify usage handling**

Run: `python3 scripts/fix_screenshot_corners.py`
Expected: exits non-zero and prints `Usage: scripts/fix_screenshot_corners.py <image.png> [more-images.png ...]`

- [ ] **Step 3: Run the script on the target screenshot**

Run: `python3 scripts/fix_screenshot_corners.py docs/images/preview-agent.png`
Expected: prints `fixed docs/images/preview-agent.png (` followed by the transparent pixel count

- [ ] **Step 4: Commit the script and image change**

```bash
git add scripts/fix_screenshot_corners.py docs/images/preview-agent.png
git commit -m "fix: add screenshot corner cleanup script"
```

### Task 2: Verify the resulting image format and repo health

**Files:**
- Verify: `docs/images/preview-agent.png`
- Verify: `pulse.xcodeproj`, app sources via build

- [ ] **Step 1: Verify the PNG still has an alpha channel**

Run:

```bash
python3 - <<'EOF'
from PIL import Image
img = Image.open('docs/images/preview-agent.png')
print(img.mode, img.size)
EOF
```

Expected: output starts with `RGBA`

- [ ] **Step 2: Build the app to satisfy repository verification rules**

Run: `xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Review the worktree summary**

Run: `git status --short`
Expected: shows the intended script and image changes, plus any unrelated pre-existing worktree changes left untouched

- [ ] **Step 4: Commit verification-complete state if not already committed**

```bash
git add scripts/fix_screenshot_corners.py docs/images/preview-agent.png
git commit -m "fix: remove screenshot corner bleed"
```

## Self-Review

- Spec coverage: the plan adds a reusable in-place PNG script, applies it to `docs/images/preview-agent.png`, includes error handling, and verifies alpha-channel output plus repo build health.
- Placeholder scan: no `TBD`, `TODO`, or undefined steps remain.
- Type consistency: the script entry point, helper name, CLI path, and verification commands are consistent across all tasks.
