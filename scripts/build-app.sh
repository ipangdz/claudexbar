#!/bin/sh
set -eu

# Build a universal (arm64 + x86_64) ClaudexBar.app for distribution
# (GitHub release asset / Homebrew cask). Local users install from source with
# scripts/install.sh instead; this is for CI release artifacts.
#
# Usage: scripts/build-app.sh [output-dir]     (default: dist)
# Version: $VERSION if set, else CFBundleShortVersionString from install.sh.

APP_NAME="ClaudexBar"
LABEL="com.ipang.claudexbar"

cd "$(dirname "$0")/.."

OUT_DIR="${1:-dist}"
APP_DIR="${OUT_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

VERSION="${VERSION:-$(grep -A1 CFBundleShortVersionString scripts/install.sh | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)}"
VERSION="${VERSION:-0.0.0}"

swift build -c release --arch arm64 --arch x86_64
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod 755 "${MACOS_DIR}/${APP_NAME}"
cp "Sources/ClaudexBarApp/Resources/AppIcon.icns" "${RES_DIR}/AppIcon.icns"

cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${LABEL}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

printf '%s\n' "Built ${APP_DIR} (version ${VERSION}, universal arm64+x86_64)"
