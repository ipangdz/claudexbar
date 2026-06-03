#!/bin/sh
set -eu

APP_NAME="ClaudexBar"
LABEL="com.ipang.claudexbar"
BIN_PATH="${HOME}/.local/bin/claudexbar"
APP_DIR="${HOME}/Applications/${APP_NAME}.app"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
SUPPORT_DIR="${HOME}/Library/Application Support/${APP_NAME}"
LOG_DIR="${HOME}/Library/Logs/${APP_NAME}"

launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" >/dev/null 2>&1 || true
rm -f "${PLIST_PATH}" "${BIN_PATH}"
rm -rf "${APP_DIR}"
rm -rf "${SUPPORT_DIR}" "${LOG_DIR}"

printf '%s\n' "Uninstalled ${APP_NAME}"
