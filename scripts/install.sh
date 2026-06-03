#!/bin/sh
set -eu

APP_NAME="ClaudexBar"
LABEL="com.ipang.claudexbar"
BIN_DIR="${HOME}/.local/bin"
BIN_PATH="${BIN_DIR}/claudexbar"
APP_DIR="${HOME}/Applications/${APP_NAME}.app"
APP_BIN_DIR="${APP_DIR}/Contents/MacOS"
APP_RESOURCES_DIR="${APP_DIR}/Contents/Resources"
APP_BIN_PATH="${APP_BIN_DIR}/${APP_NAME}"
LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${LAUNCH_AGENT_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/${APP_NAME}"

cd "$(dirname "$0")/.."

swift build -c release

mkdir -p "${BIN_DIR}" "${APP_BIN_DIR}" "${APP_RESOURCES_DIR}" "${LAUNCH_AGENT_DIR}" "${LOG_DIR}"
cp ".build/release/${APP_NAME}" "${APP_BIN_PATH}"
chmod 755 "${APP_BIN_PATH}"
ln -sf "${APP_BIN_PATH}" "${BIN_PATH}"

# App icon (shown in Finder/Spotlight; the app itself is a menu-bar accessory).
if [ -f "Sources/ClaudexBarApp/Resources/AppIcon.icns" ]; then
  cp "Sources/ClaudexBarApp/Resources/AppIcon.icns" "${APP_RESOURCES_DIR}/AppIcon.icns"
fi
: > "${LOG_DIR}/claudexbar.out.log"
: > "${LOG_DIR}/claudexbar.err.log"

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
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF

# Ad-hoc code signing ("-"): a stable local identity, no Apple account needed.
# (Override CODESIGN_IDENTITY only if you have a real signing certificate.)
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if codesign --force --deep --sign "${CODESIGN_IDENTITY}" "${APP_DIR}" >/dev/null 2>&1; then
  printf '%s\n' "Signed ${APP_NAME} (identity: ${CODESIGN_IDENTITY})"
else
  printf '%s\n' "Warning: codesign failed (identity: ${CODESIGN_IDENTITY}); continuing unsigned"
fi
# Nudge Finder/LaunchServices to pick up the new icon.
touch "${APP_DIR}"

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${APP_BIN_PATH}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/claudexbar.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/claudexbar.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"

printf '%s\n' "Installed ${APP_NAME} at ${APP_DIR}"
