# Screenshot Corner Fix Design

## Goal

Fix rounded-corner screenshot artifacts in `docs/images/` by adding a reusable script that converts the background bleed captured outside the app panel into transparent pixels.

## Scope

- Add a small script under `scripts/`
- Accept one or more PNG paths as arguments
- Update images in place by default
- Apply the script to `docs/images/preview-agent.png`

## Approach

The script will:

1. Open each PNG as RGBA
2. Flood-fill from all four corners
3. Treat connected low-intensity pixels as outside-the-panel background bleed
4. Set those pixels' alpha channel to `0`
5. Save the result back to the same file

This keeps the existing panel border and interior untouched while making the corner regions transparent.

## Why This Approach

- It matches the existing screenshots that already needed the same cleanup
- It avoids hand-editing screenshots in an image editor
- It stays narrow in scope and does not require changing the screenshot capture pipeline yet
- It is safe for the current image set because the unwanted pixels are contiguous from the image corners

## Trade-Offs

### Recommended: corner flood-fill to transparency

- Pros: simple, repeatable, minimal user effort
- Cons: tuned to this screenshot style rather than being a universal image-processing tool

### One-off manual fix

- Pros: fastest for a single image
- Cons: repeats the same work every time a new screenshot is added

### More configurable tool with multiple modes

- Pros: more flexible for future image styles
- Cons: unnecessary complexity for the current need

## Error Handling

- If a file is missing, the script should print an error and continue to the next file
- If a file is not a PNG or cannot be opened, the script should print an error and continue
- If no paths are provided, the script should print usage text and exit non-zero

## Verification

- Run the script on `docs/images/preview-agent.png`
- Confirm the file remains a PNG with an alpha channel
- Build the app afterward to satisfy repo verification rules, even though the change is documentation/tooling only
