#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Pulse"
VERSION="1.1.0"
SCHEME="pulse"
PROJECT="pulse.xcodeproj"
CONFIG="Release"
DIST_DIR="dist"
STAGING_DIR="/tmp/${APP_NAME}-dmg-staging"

echo "==> Building ${APP_NAME} (${CONFIG})..."
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  build

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "${APP_NAME}.app" \
  -path "*/${CONFIG}/*" \
  | head -1)

if [ -z "${APP_PATH}" ]; then
  echo "ERROR: Could not find built .app" >&2
  exit 1
fi

echo "==> Found app at: ${APP_PATH}"

mkdir -p "${DIST_DIR}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

DMG_TMP="/tmp/${APP_NAME}-tmp.dmg"
DMG_OUT="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

echo "==> Creating DMG..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_TMP}"

mv "${DMG_TMP}" "${DMG_OUT}"
rm -rf "${STAGING_DIR}"

echo "==> Done: ${DMG_OUT}"
